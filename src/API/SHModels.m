#import "SHModels.h"
#import "SHCommon.h"

@implementation SHUser

+ (instancetype)fromJSON:(NSDictionary *)json
{
    NSDictionary *d = SHDict(json);
    if (!d) return nil;
    SHUser *u = [[SHUser alloc] init];
    u.pk = SHStr(d[@"pk"]) ?: SHStr(d[@"pk_id"]) ?: @"";
    u.username = SHStr(d[@"username"]) ?: @"";
    u.fullName = SHStr(d[@"full_name"]) ?: @"";
    u.biography = SHStr(d[@"biography"]) ?: @"";
    u.profilePicURL = SHStr(d[@"profile_pic_url"]) ?: @"";
    u.followerCount = SHInt(d[@"follower_count"]);
    u.followingCount = SHInt(d[@"following_count"]);
    u.mediaCount = SHInt(d[@"media_count"]);
    u.isPrivate = SHBool(d[@"is_private"]);
    u.isVerified = SHBool(d[@"is_verified"]);
    NSDictionary *fs = SHDict(d[@"friendship_status"]);
    if (fs) {
        u.friendshipFollowing = SHBool(fs[@"following"]);
        u.friendshipFollowedBy = SHBool(fs[@"followed_by"]);
    }
    return u;
}

@end

@implementation SHMediaImage

+ (instancetype)bestFromCandidates:(NSArray *)candidates
{
    NSArray *arr = SHArr(candidates);
    if (!arr.count) return nil;
    NSDictionary *best = nil;
    NSInteger bestW = 0;
    for (NSDictionary *c in arr) {
        NSInteger w = SHInt(c[@"width"]);
        if (w > bestW) { best = c; bestW = w; }
    }
    if (!best) best = arr[0];
    SHMediaImage *img = [[SHMediaImage alloc] init];
    img.url = SHStr(best[@"url"]) ?: @"";
    img.width = SHInt(best[@"width"]);
    img.height = SHInt(best[@"height"]);
    return img;
}

@end

@implementation SHPost

+ (instancetype)fromJSON:(NSDictionary *)json
{
    NSDictionary *d = SHDict(json);
    if (!d) return nil;
    SHPost *p = [[SHPost alloc] init];
    p.pk = SHStr(d[@"pk"]) ?: SHStr(d[@"id"]) ?: @"";
    p.code = SHStr(d[@"code"]) ?: @"";
    p.mediaType = SHInt(d[@"media_type"]);
    p.user = [SHUser fromJSON:SHDict(d[@"user"])];
    p.image = [SHMediaImage bestFromCandidates:SHArr(d[@"image_versions2"][@"candidates"])];
    NSArray *videoVersions = SHArr(d[@"video_versions"]);
    if (videoVersions.count) {
        NSDictionary *best = nil;
        NSInteger bestW = 0;
        for (NSDictionary *v in videoVersions) {
            NSInteger w = SHInt(v[@"width"]);
            if (w > bestW) { best = v; bestW = w; }
        }
        if (!best) best = videoVersions[0];
        p.videoURL = SHStr(best[@"url"]) ?: @"";
    }
    p.videoDuration = SHDbl(d[@"video_duration"]);
    NSDictionary *caption = SHDict(d[@"caption"]);
    p.captionText = caption ? (SHStr(caption[@"text"]) ?: @"") : @"";
    p.likeCount = SHInt(d[@"like_count"]);
    p.commentCount = SHInt(d[@"comment_count"]);
    p.hasLiked = SHBool(d[@"has_liked"]);
    NSTimeInterval ts = SHDbl(d[@"taken_at"]);
    p.takenAt = ts > 0 ? [NSDate dateWithTimeIntervalSince1970:ts] : nil;

    NSArray *carousel = SHArr(d[@"carousel_media"]);
    if (carousel.count) {
        NSMutableArray *items = [NSMutableArray array];
        for (NSDictionary *cm in carousel) {
            SHPost *sub = [SHPost fromJSON:cm];
            if (sub) {
                if (!sub.user) sub.user = p.user;
                [items addObject:sub];
            }
        }
        p.carouselMedia = items;
    }
    return p;
}

@end

@implementation SHComment

+ (instancetype)fromJSON:(NSDictionary *)json
{
    NSDictionary *d = SHDict(json);
    if (!d) return nil;
    SHComment *c = [[SHComment alloc] init];
    c.pk = SHStr(d[@"pk"]) ?: @"";
    c.user = [SHUser fromJSON:SHDict(d[@"user"])];
    c.text = SHStr(d[@"text"]) ?: @"";
    NSTimeInterval ts = SHDbl(d[@"created_at"]);
    c.createdAt = ts > 0 ? [NSDate dateWithTimeIntervalSince1970:ts] : nil;
    c.likeCount = SHInt(d[@"comment_like_count"]);
    return c;
}

@end

@implementation SHStoryItem

+ (instancetype)fromJSON:(NSDictionary *)json
{
    NSDictionary *d = SHDict(json);
    if (!d) return nil;
    SHStoryItem *s = [[SHStoryItem alloc] init];
    s.pk = SHStr(d[@"pk"]) ?: @"";
    s.mediaType = SHInt(d[@"media_type"]);
    s.image = [SHMediaImage bestFromCandidates:SHArr(d[@"image_versions2"][@"candidates"])];
    NSArray *videoVersions = SHArr(d[@"video_versions"]);
    if (videoVersions.count) {
        NSDictionary *best = nil;
        NSInteger bestW = 0;
        for (NSDictionary *v in videoVersions) {
            NSInteger w = SHInt(v[@"width"]);
            if (w > bestW) { best = v; bestW = w; }
        }
        if (!best) best = videoVersions[0];
        s.videoURL = SHStr(best[@"url"]) ?: @"";
    }
    s.videoDuration = SHDbl(d[@"video_duration"]);
    NSTimeInterval ts = SHDbl(d[@"taken_at"]);
    s.takenAt = ts > 0 ? [NSDate dateWithTimeIntervalSince1970:ts] : nil;
    s.expiringAt = SHDbl(d[@"expiring_at"]);
    return s;
}

@end

@implementation SHStoryReel

+ (instancetype)fromJSON:(NSDictionary *)json
{
    NSDictionary *d = SHDict(json);
    if (!d) return nil;
    SHStoryReel *r = [[SHStoryReel alloc] init];
    r.user = [SHUser fromJSON:SHDict(d[@"user"])];
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *item in SHArr(d[@"items"])) {
        SHStoryItem *s = [SHStoryItem fromJSON:item];
        if (s) [items addObject:s];
    }
    r.items = items;
    r.seen = SHDbl(d[@"seen"]) > 0;
    return r;
}

@end
