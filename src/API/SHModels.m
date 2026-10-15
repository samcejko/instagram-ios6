#import "SHModels.h"
#import "SHCommon.h"

@implementation SHUser

+ (instancetype)fromJSON:(NSDictionary *)json
{
    NSDictionary *d = SHDict(json);
    if (!d) return nil;
    SHUser *u = [[SHUser alloc] init];
    // mobile API fields first, the web profile's (web_profile_info: id, edge_* counts, *_by_viewer) as fallbacks
    u.pk = SHStr(d[@"pk"]) ?: SHStr(d[@"pk_id"]) ?: SHStr(d[@"id"]) ?: @"";
    u.username = SHStr(d[@"username"]) ?: @"";
    u.fullName = SHStr(d[@"full_name"]) ?: @"";
    u.biography = SHStr(d[@"biography"]) ?: @"";
    u.profilePicURL = SHStr(d[@"profile_pic_url_hd"]) ?: SHStr(d[@"profile_pic_url"]) ?: @"";
    u.followerCount = d[@"follower_count"] ? SHInt(d[@"follower_count"]) : SHInt(SHDict(d[@"edge_followed_by"])[@"count"]);
    u.followingCount = d[@"following_count"] ? SHInt(d[@"following_count"]) : SHInt(SHDict(d[@"edge_follow"])[@"count"]);
    u.mediaCount = d[@"media_count"] ? SHInt(d[@"media_count"]) : SHInt(SHDict(d[@"edge_owner_to_timeline_media"])[@"count"]);
    u.isPrivate = SHBool(d[@"is_private"]);
    u.isVerified = SHBool(d[@"is_verified"]);
    NSDictionary *fs = SHDict(d[@"friendship_status"]);
    if (fs) {
        u.friendshipFollowing = SHBool(fs[@"following"]);
        u.friendshipFollowedBy = SHBool(fs[@"followed_by"]);
        u.friendshipRequested = SHBool(fs[@"outgoing_request"]);
    } else {
        u.friendshipFollowing = SHBool(d[@"followed_by_viewer"]);
        u.friendshipFollowedBy = SHBool(d[@"follows_viewer"]);
        u.friendshipRequested = SHBool(d[@"requested_by_viewer"]);
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

+ (instancetype)candidateFromCandidates:(NSArray *)candidates minWidth:(NSInteger)minWidth
{
    NSArray *arr = SHArr(candidates);
    if (!arr.count) return nil;
    NSDictionary *pick = nil;
    for (NSDictionary *c in arr) {
        NSInteger w = SHInt(c[@"width"]);
        if (w < minWidth) continue;
        if (!pick || w < SHInt(pick[@"width"])) pick = c;
    }
    if (!pick) return [self bestFromCandidates:arr];
    SHMediaImage *img = [[SHMediaImage alloc] init];
    img.url = SHStr(pick[@"url"]) ?: @"";
    img.width = SHInt(pick[@"width"]);
    img.height = SHInt(pick[@"height"]);
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
    NSArray *candidates = SHArr(d[@"image_versions2"][@"candidates"]);
    p.image = [SHMediaImage bestFromCandidates:candidates];
    p.mediumImage = [SHMediaImage candidateFromCandidates:candidates minWidth:640] ?: p.image;
    p.thumbImage = [SHMediaImage candidateFromCandidates:candidates minWidth:300] ?: p.mediumImage;
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
    p.saved = SHBool(d[@"has_viewer_saved"]);
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

@implementation SHNewsStory

+ (instancetype)fromJSON:(NSDictionary *)json
{
    NSDictionary *d = SHDict(json);
    if (!d) return nil;
    SHNewsStory *n = [[SHNewsStory alloc] init];
    NSDictionary *args = SHDict(d[@"args"]);
    n.text = SHStr(args[@"text"]) ?: @"";
    if (!n.text.length) {
        // newer items carry "rich_text" with {username|id} markers; keep just the name
        NSString *rich = SHStr(args[@"rich_text"]) ?: @"";
        NSMutableString *out = [NSMutableString string];
        NSScanner *sc = [NSScanner scannerWithString:rich];
        sc.charactersToBeSkipped = nil;
        while (![sc isAtEnd]) {
            NSString *plain = nil;
            if ([sc scanUpToString:@"{" intoString:&plain]) [out appendString:plain];
            if ([sc scanString:@"{" intoString:NULL]) {
                NSString *inner = nil;
                [sc scanUpToString:@"}" intoString:&inner];
                [sc scanString:@"}" intoString:NULL];
                [out appendString:[[inner componentsSeparatedByString:@"|"] firstObject] ?: @""];
            }
        }
        n.text = out;
    }
    NSTimeInterval ts = SHDbl(args[@"timestamp"]);
    n.timestamp = ts > 0 ? [NSDate dateWithTimeIntervalSince1970:ts] : nil;
    n.profilePicURL = SHStr(args[@"profile_image"]) ?: @"";
    // The related media, when the story is about a post (a like/comment): a small thumbnail and its id.
    NSDictionary *media = SHDict([SHArr(args[@"media"]) firstObject]);
    n.mediaThumbURL = SHStr(media[@"image"]) ?: @"";
    n.mediaPk = SHStr(media[@"id"]) ?: @"";
    NSArray *links = SHArr(args[@"links"]);
    NSDictionary *link = SHDict([links firstObject]);
    n.userPk = SHStr(args[@"profile_id"]) ?: SHStr(link[@"id"]) ?: @"";
    n.username = SHStr(args[@"profile_name"]) ?: @"";
    if (!n.text.length) return nil;
    return n;
}

@end

@implementation SHDirectMessage

+ (instancetype)fromJSON:(NSDictionary *)json
{
    NSDictionary *d = SHDict(json);
    if (!d) return nil;
    SHDirectMessage *m = [[SHDirectMessage alloc] init];
    m.pk = SHStr(d[@"item_id"]) ?: @"";
    m.type = SHStr(d[@"item_type"]) ?: @"";
    m.senderPk = SHStr(d[@"user_id"]) ?: @"";
    NSTimeInterval ts = SHDbl(d[@"timestamp"]);   // microseconds
    if (ts > 1e14) ts /= 1e6;
    m.timestamp = ts > 0 ? [NSDate dateWithTimeIntervalSince1970:ts] : nil;

    if ([m.type isEqualToString:@"text"]) {
        m.text = SHStr(d[@"text"]) ?: @"";
    } else if ([m.type isEqualToString:@"like"]) {
        m.text = SHStr(d[@"like"]) ?: @"❤";   // a heart
    } else if ([m.type isEqualToString:@"link"]) {
        m.text = SHStr(SHDict(d[@"link"])[@"text"]) ?: @"";
    } else if ([m.type isEqualToString:@"media"]) {
        // a photo or video sent directly
        NSDictionary *media = SHDict(d[@"media"]);
        m.previewURL = [SHMediaImage candidateFromCandidates:SHArr(media[@"image_versions2"][@"candidates"]) minWidth:300].url ?: @"";
        NSDictionary *vv = SHDict([SHArr(media[@"video_versions"]) firstObject]);
        m.videoURL = SHStr(vv[@"url"]);
        m.placeholderText = m.videoURL.length ? L(@"Video") : L(@"Photo");
    } else if ([m.type isEqualToString:@"media_share"] || [m.type isEqualToString:@"clip"] || [m.type isEqualToString:@"felix_share"]) {
        NSDictionary *media = SHDict(d[@"media_share"]) ?: SHDict(SHDict(d[@"clip"])[@"clip"]) ?: SHDict(SHDict(d[@"felix_share"])[@"video"]);
        m.sharedPost = [SHPost fromJSON:media];
        m.previewURL = m.sharedPost.thumbImage.url ?: @"";
        NSString *who = m.sharedPost.user.username;
        m.placeholderText = who.length ? [NSString stringWithFormat:L(@"Shared a post by %@"), who] : L(@"Shared a post");
    } else if ([m.type isEqualToString:@"story_share"]) {
        NSDictionary *media = SHDict(SHDict(d[@"story_share"])[@"media"]);
        m.previewURL = [SHMediaImage candidateFromCandidates:SHArr(media[@"image_versions2"][@"candidates"]) minWidth:300].url ?: @"";
        m.placeholderText = L(@"Shared a story");
    } else if ([m.type isEqualToString:@"voice_media"]) {
        NSDictionary *audio = SHDict(SHDict(SHDict(d[@"voice_media"])[@"media"])[@"audio"]);
        m.audioURL = SHStr(audio[@"audio_src"]);
        m.audioDuration = SHDbl(audio[@"duration"]) / 1000.0;   // milliseconds
        m.placeholderText = L(@"Voice message");
    } else if ([m.type isEqualToString:@"animated_media"]) {
        NSDictionary *images = SHDict(SHDict(d[@"animated_media"])[@"images"]);
        m.previewURL = SHStr(SHDict(images[@"fixed_height"])[@"url"]) ?: @"";
        m.placeholderText = @"GIF";
    } else if ([m.type isEqualToString:@"action_log"]) {
        m.placeholderText = SHStr(SHDict(d[@"action_log"])[@"description"]) ?: @"";
    } else {
        m.placeholderText = SHStr(d[@"text"]) ?: L(@"Unsupported message");
    }
    return m;
}

@end

@implementation SHDirectThread

+ (instancetype)fromJSON:(NSDictionary *)json
{
    NSDictionary *d = SHDict(json);
    if (!d) return nil;
    SHDirectThread *t = [[SHDirectThread alloc] init];
    t.threadId = SHStr(d[@"thread_id"]) ?: @"";

    NSMutableArray *users = [NSMutableArray array];
    for (NSDictionary *u in SHArr(d[@"users"])) {
        SHUser *user = [SHUser fromJSON:u];
        if (user) [users addObject:user];
    }
    t.users = users;

    NSString *title = SHStr(d[@"thread_title"]);
    if (!title.length) {
        NSMutableArray *names = [NSMutableArray array];
        for (SHUser *u in users) if (u.username.length) [names addObject:u.username];
        title = [names componentsJoinedByString:@", "];
    }
    t.title = title.length ? title : L(@"Direct");

    NSMutableArray *messages = [NSMutableArray array];
    for (NSDictionary *item in SHArr(d[@"items"])) {
        SHDirectMessage *m = [SHDirectMessage fromJSON:item];
        if (m) [messages addObject:m];
    }
    t.messages = messages;

    SHDirectMessage *last = [messages firstObject];
    t.lastText = last.text.length ? last.text : (last.placeholderText ?: @"");
    t.lastActivity = last.timestamp;
    t.unread = SHInt(d[@"read_state"]) != 0;
    return t;
}

@end
