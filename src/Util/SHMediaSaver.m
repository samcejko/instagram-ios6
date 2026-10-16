#import "SHMediaSaver.h"
#import "SHModels.h"
#import "SHHTTP.h"
#import "SHInstagram.h"
#import "SHShareViewController.h"
#import "SHUtils.h"
#import "SHCommon.h"
#import <UIKit/UIKit.h>

// One thing to save: a picture or a video, by its address.
@interface SHSaveJob : NSObject
@property (nonatomic, copy) NSString *url;
@property (nonatomic) BOOL video;
@end
@implementation SHSaveJob
@end

@interface SHMediaSaver ()
@property (nonatomic, strong) NSMutableArray *queue;   // SHSaveJob, the first one is under way
@property (nonatomic) NSUInteger saved;
@property (nonatomic) NSUInteger failed;
@property (nonatomic, copy) NSString *problem;         // the reason of the last failure, for the notice
@property (nonatomic, copy) NSString *tempPath;        // the video file being handed to the library
@end

@implementation SHMediaSaver

+ (instancetype)shared
{
    static SHMediaSaver *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[SHMediaSaver alloc] init]; s.queue = [NSMutableArray array]; });
    return s;
}

+ (void)addPost:(SHPost *)post to:(NSMutableArray *)jobs
{
    if (post.carouselMedia.count) {
        for (SHPost *item in post.carouselMedia) [self addPost:item to:jobs];
        return;
    }
    SHSaveJob *job = [[SHSaveJob alloc] init];
    job.video = post.videoURL.length > 0;
    job.url = job.video ? post.videoURL : post.image.url;
    if (job.url.length) [jobs addObject:job];
}

+ (void)savePost:(SHPost *)post
{
    NSMutableArray *jobs = [NSMutableArray array];
    [self addPost:post to:jobs];
    [[self shared] enqueue:jobs];
}

+ (void)saveImageURL:(NSString *)imageURL videoURL:(NSString *)videoURL
{
    SHSaveJob *job = [[SHSaveJob alloc] init];
    job.video = videoURL.length > 0;
    job.url = job.video ? videoURL : imageURL;
    [[self shared] enqueue:job.url.length ? @[ job ] : @[]];
}

- (void)enqueue:(NSArray *)jobs
{
    if (!jobs.count) { [SHShareViewController flashMessage:L(@"Nothing to save")]; return; }
    BOOL idle = _queue.count == 0;
    if (idle) { _saved = 0; _failed = 0; _problem = nil; }
    [_queue addObjectsFromArray:jobs];
    [SHShareViewController flashMessage:L(@"Saving...")];
    if (idle) [self next];
}

// The next one, or the notice once all are through.
- (void)next
{
    SHSaveJob *job = [_queue firstObject];
    if (!job) {
        if (_failed == 0) [SHShareViewController flashMessage:L(@"Saved to Photos")];
        else [SHUtils alertWithTitle:L(@"Save to Photos") message:_problem ?: L(@"Couldn't save it.")];
        return;
    }
    NSDictionary *headers = @{ @"User-Agent": [SHInstagram appUserAgent] };
    [SHHTTP request:@"GET" url:job.url headers:headers body:nil retries:1
         completion:^(NSInteger status, NSData *body, NSDictionary *responseHeaders, NSError *error) {
        if (error || status >= 400 || !body.length) {
            [self finished:NO problem:error.localizedDescription ?: [NSString stringWithFormat:L(@"Request failed (HTTP %ld)."), (long)status]];
            return;
        }
        if (job.video) [self saveVideoData:body];
        else [self saveImageData:body];
    }];
}

- (void)finished:(BOOL)ok problem:(NSString *)problem
{
    if (ok) _saved++;
    else { _failed++; _problem = problem; }
    if (_queue.count) [_queue removeObjectAtIndex:0];
    [self next];
}

// What the library said, in words: no access (a setting the user decides) or its own reason.
- (NSString *)problemOf:(NSError *)error
{
    // ALAssetsLibraryAccessUserDeniedError / AccessGloballyDeniedError (-3311, -3310): Photos are not allowed
    if (error.code == -3311 || error.code == -3310)
        return L(@"Gramify may not use your photos. Allow it in Settings > Privacy > Photos.");
    return error.localizedDescription ?: L(@"Couldn't save it.");
}

- (void)saveImageData:(NSData *)data
{
    UIImage *image = [UIImage imageWithData:data];
    if (!image) { [self finished:NO problem:L(@"Couldn't save it.")]; return; }
    UIImageWriteToSavedPhotosAlbum(image, self, @selector(image:didFinishSavingWithError:contextInfo:), NULL);
}

- (void)image:(UIImage *)image didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo
{
    [self finished:error == nil problem:error ? [self problemOf:error] : nil];
}

- (void)saveVideoData:(NSData *)data
{
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"gramify-%@.mp4", [[NSUUID UUID] UUIDString]]];
    if (![data writeToFile:path atomically:YES]) { [self finished:NO problem:L(@"Couldn't save it.")]; return; }
    if (!UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(path)) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        [self finished:NO problem:L(@"This video can't be kept in the photo library of this device.")];
        return;
    }
    _tempPath = path;
    UISaveVideoAtPathToSavedPhotosAlbum(path, self, @selector(video:didFinishSavingWithError:contextInfo:), NULL);
}

- (void)video:(NSString *)videoPath didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo
{
    if (_tempPath) [[NSFileManager defaultManager] removeItemAtPath:_tempPath error:NULL];
    _tempPath = nil;
    [self finished:error == nil problem:error ? [self problemOf:error] : nil];
}

@end
