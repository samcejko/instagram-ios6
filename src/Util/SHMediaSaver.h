#import <Foundation/Foundation.h>

@class SHPost;

// Photos and videos into the device's photo library (Camera Roll): a post (every picture and video of it) or one
// picture or video by its address. Downloaded through the app's own TLS stack, one after the other; a short notice
// says when they are in, or why not (the photo library not allowed in Settings, a video this device cannot keep).
@interface SHMediaSaver : NSObject
+ (void)savePost:(SHPost *)post;
+ (void)saveImageURL:(NSString *)imageURL videoURL:(NSString *)videoURL;   // the video when there is one, else the picture
@end
