#import "SHModels.h"
#import "SHSettings.h"
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

    NSMutableArray *tags = [NSMutableArray array];
    for (id t in SHArr(SHDict(d[@"usertags"])[@"in"])) {
        NSDictionary *td = SHDict(t);
        NSArray *position = SHArr(td[@"position"]);
        SHUser *u = [SHUser fromJSON:SHDict(td[@"user"])];
        if (!u.username.length || position.count < 2) continue;
        SHUserTag *tag = [[SHUserTag alloc] init];
        tag.user = u;
        tag.x = MAX(0, MIN(1, SHDbl(position[0])));
        tag.y = MAX(0, MIN(1, SHDbl(position[1])));
        [tags addObject:tag];
    }
    p.userTags = tags;

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

@implementation SHUserTag
@end

@implementation SHStoryMention
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

    // "@name" stickers: reel_mentions, and the newer bloks stickers (sticker_data.ig_mention)
    NSMutableArray *mentions = [NSMutableArray array];
    NSMutableSet *names = [NSMutableSet set];
    void (^add)(SHUser *, NSDictionary *) = ^(SHUser *u, NSDictionary *place) {
        if (!u.username.length || [names containsObject:u.username]) return;
        SHStoryMention *m = [[SHStoryMention alloc] init];
        m.user = u;
        m.x = SHDbl(place[@"x"]);
        m.y = SHDbl(place[@"y"]);
        m.width = SHDbl(place[@"width"]);
        m.height = SHDbl(place[@"height"]);
        m.rotation = SHDbl(place[@"rotation"]);
        if (m.width <= 0 || m.height <= 0) return;
        [names addObject:u.username];
        [mentions addObject:m];
    };
    for (id m in SHArr(d[@"reel_mentions"])) add([SHUser fromJSON:SHDict(SHDict(m)[@"user"])], SHDict(m));
    for (id st in SHArr(d[@"story_bloks_stickers"])) {
        NSDictionary *sticker = SHDict(st);
        NSDictionary *mention = SHDict(SHDict(SHDict(sticker[@"bloks_sticker"])[@"sticker_data"])[@"ig_mention"]);
        if (!mention) continue;
        SHUser *u = [[SHUser alloc] init];
        u.pk = SHStr(mention[@"account_id"]) ?: @"";
        u.username = SHStr(mention[@"username"]) ?: @"";
        u.fullName = SHStr(mention[@"full_name"]) ?: @"";
        u.profilePicURL = SHStr(mention[@"profile_pic_url"]) ?: @"";
        add(u, sticker);
    }
    s.mentions = mentions;
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
    r.reelId = SHStr(d[@"id"]) ?: r.user.pk;
    r.title = SHStr(d[@"title"]) ?: @"";
    // a highlight's cover: a square crop of one of its pictures
    NSDictionary *cover = SHDict(d[@"cover_media"]);
    r.coverURL = SHStr(SHDict(cover[@"cropped_image_version"])[@"url"])
              ?: SHStr([SHMediaImage candidateFromCandidates:SHArr(SHDict(cover[@"image_versions2"])[@"candidates"]) minWidth:150].url) ?: @"";
    r.mediaCount = SHInt(d[@"media_count"]);
    // "seen" is the time the newest story already seen was posted; the reel is seen once that reaches its newest
    r.latestReelMedia = SHDbl(d[@"latest_reel_media"]);
    for (SHStoryItem *s in items) r.latestReelMedia = MAX(r.latestReelMedia, [s.takenAt timeIntervalSince1970]);
    r.seenUpTo = SHDbl(d[@"seen"]);
    [r updateSeen];
    return r;
}

- (void)updateSeen
{
    self.seen = self.latestReelMedia > 0 && self.seenUpTo >= self.latestReelMedia;
}

- (BOOL)isHighlight { return [self.reelId hasPrefix:@"highlight:"]; }

- (BOOL)tracksSeen { return !self.isHighlight && !self.fromChat; }

// user pk -> the post time of the newest story of theirs seen on this device; stories live a day, so entries older
// than two days are dropped whenever the list is read
static NSString * const SHSeenStoriesKey = @"SHSeenStories";

static NSMutableDictionary *SHSeenStore(void)
{
    static NSMutableDictionary *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [NSMutableDictionary dictionary];
        NSDictionary *kept = [[NSUserDefaults standardUserDefaults] dictionaryForKey:SHSeenStoriesKey];
        NSTimeInterval oldest = [[NSDate date] timeIntervalSince1970] - 2 * 86400;
        for (NSString *pk in kept) {
            NSNumber *t = kept[pk];
            if ([t isKindOfClass:[NSNumber class]] && t.doubleValue > oldest) store[pk] = t;
        }
    });
    return store;
}

- (void)noteSeenItem:(SHStoryItem *)item
{
    if (!self.tracksSeen) return;   // (a highlight's old stories, a chat's photo: not the person's ring)
    NSTimeInterval t = [item.takenAt timeIntervalSince1970];
    if (t <= self.seenUpTo) return;
    self.seenUpTo = t;
    [self updateSeen];
    if (!self.user.pk.length) return;
    NSMutableDictionary *store = SHSeenStore();
    store[self.user.pk] = @(t);
    [[NSUserDefaults standardUserDefaults] setObject:store forKey:SHSeenStoriesKey];
}

- (void)applyRememberedSeen
{
    if (!self.tracksSeen) return;
    NSTimeInterval t = [SHSeenStore()[self.user.pk ?: @""] doubleValue];
    if (t <= self.seenUpTo) return;
    self.seenUpTo = t;
    [self updateSeen];
}

- (NSUInteger)firstUnseenIndex
{
    for (NSUInteger i = 0; i < self.items.count; i++) {
        if ([[self.items[i] takenAt] timeIntervalSince1970] > self.seenUpTo) return i;
    }
    return 0;   // all seen: from the start again
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

// The "view once" pictures opened on this device (item ids, the last few hundred).
static NSString * const SHOpenedEphemeralKey = @"SHOpenedEphemeral";

+ (BOOL)ephemeralOpened:(NSString *)pk
{
    return pk.length && [[[NSUserDefaults standardUserDefaults] arrayForKey:SHOpenedEphemeralKey] containsObject:pk];
}

+ (void)noteEphemeralOpened:(NSString *)pk
{
    if (!pk.length || [self ephemeralOpened:pk]) return;
    NSMutableArray *list = [[[NSUserDefaults standardUserDefaults] arrayForKey:SHOpenedEphemeralKey] mutableCopy] ?: [NSMutableArray array];
    [list addObject:pk];
    while (list.count > 300) [list removeObjectAtIndex:0];
    [[NSUserDefaults standardUserDefaults] setObject:list forKey:SHOpenedEphemeralKey];
}

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
        // a heart sent on its own: the bubble draws one; lists say it in words (no emoji in the interface)
        m.placeholderText = L(@"Sent a heart");
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
    } else if ([m.type isEqualToString:@"raven_media"]) {
        // A photo or video from the chat's camera. "permanent" ones stay in the chat like any picture; "once" and
        // "replayable" ones are opened on purpose (the sender learns it), and once seen Instagram sends no picture.
        NSDictionary *vm = SHDict(d[@"visual_media"]);
        NSDictionary *media = SHDict(vm[@"media"]);
        NSArray *candidates = SHArr(SHDict(media[@"image_versions2"])[@"candidates"]);
        m.viewMode = SHStr(vm[@"view_mode"]) ?: @"";
        m.videoURL = SHStr(SHDict([SHArr(media[@"video_versions"]) firstObject])[@"url"]);
        BOOL video = m.videoURL.length || SHInt(media[@"media_type"]) == 2;
        m.ephemeral = [m.viewMode isEqualToString:@"once"] || [m.viewMode isEqualToString:@"replayable"];
        if (m.ephemeral) {
            m.ephemeralURL = [SHMediaImage candidateFromCandidates:candidates minWidth:640].url;
            // one opened here already ("once") is not offered again, also when Instagram still lists the picture
            if ([m.viewMode isEqualToString:@"once"] && [SHDirectMessage ephemeralOpened:m.pk]) { m.ephemeralURL = nil; m.videoURL = nil; }
            BOOL openable = m.ephemeralURL.length || m.videoURL.length;
            if ([m.senderPk isEqualToString:[SHSettings userId] ?: @""]) m.placeholderText = video ? L(@"Video") : L(@"Photo");
            else m.placeholderText = openable ? (video ? L(@"Tap to view the video") : L(@"Tap to view the photo"))
                                              : (video ? L(@"Opened video") : L(@"Opened photo"));
        } else {
            m.previewURL = [SHMediaImage candidateFromCandidates:candidates minWidth:300].url ?: @"";
            m.placeholderText = video ? L(@"Video") : L(@"Photo");
        }
        if (!m.videoURL.length) m.videoURL = nil;
        m.mediaIsVideo = video;
        // (debug builds: what such an item carries, once per item)
        static NSMutableSet *logged;
        if (!logged) logged = [NSMutableSet set];
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        if (m.pk.length && ![logged containsObject:m.pk] && [[NSFileManager defaultManager] fileExistsAtPath:[docs stringByAppendingPathComponent:@"debug"]]) {
            [logged addObject:m.pk];
            SHLog(@"DMITEM raven view_mode=%@ image=%d video=%d seen_count=%@ seen_users=%lu media_keys=%@", m.viewMode,
                  candidates.count > 0, m.videoURL.length > 0, SHStr(vm[@"seen_count"]) ?: @"-", (unsigned long)SHArr(vm[@"seen_user_ids"]).count,
                  [[media allKeys] componentsJoinedByString:@","]);
        }
    } else if ([m.type isEqualToString:@"animated_media"]) {
        NSDictionary *images = SHDict(SHDict(d[@"animated_media"])[@"images"]);
        m.previewURL = SHStr(SHDict(images[@"fixed_height"])[@"url"]) ?: @"";
        m.placeholderText = @"GIF";
    } else if ([m.type hasPrefix:@"xma"] || [m.type isEqualToString:@"generic_xma"] || SHArr(d[@"generic_xma"]).count) {
        // The newer form of a shared post, reel or story ("xma_media_share", "xma_clip", "xma_story_share", …): a list
        // with a preview picture, the link to the thing and whose it is
        NSDictionary *x = SHDict([SHArr(d[m.type]) firstObject]) ?: SHDict([SHArr(d[@"generic_xma"]) firstObject]);
        m.previewURL = SHStr(x[@"preview_url"]) ?: SHStr(SHDict(x[@"preview_url_info"])[@"url"]) ?: @"";
        m.targetURL = SHStr(x[@"target_url"]);
        m.shareTitle = SHStr(x[@"header_title_text"]);
        BOOL story = [m.type rangeOfString:@"story"].location != NSNotFound || [m.type rangeOfString:@"reel_mention"].location != NSNotFound;
        if (story) m.placeholderText = L(@"Shared a story");
        else m.placeholderText = m.shareTitle.length ? [NSString stringWithFormat:L(@"Shared a post by %@"), m.shareTitle] : L(@"Shared a post");
        if (!m.previewURL.length && !m.targetURL.length) m.placeholderText = SHStr(x[@"title_text"]) ?: m.placeholderText;
    } else if ([m.type isEqualToString:@"video_call_event"]) {
        // A call in the chat's history, as a line of its own: said in the user's language (Instagram's English words
        // only as the last resort), audio or video, missed, started or ended, with how long it took when told.
        NSDictionary *call = SHDict(d[@"video_call_event"]);
        NSString *action = [SHStr(call[@"action"]) lowercaseString] ?: @"";
        NSString *words = [[SHStr(call[@"description"]) ?: @"" lowercaseString] stringByAppendingFormat:@" %@", action];
        BOOL audio = SHBool(call[@"thread_has_audio_only_call"]) || SHBool(call[@"is_audio_only"]) || SHBool(d[@"is_audio_only"])
                  || [words rangeOfString:@"audio"].location != NSNotFound || [words rangeOfString:@"voice"].location != NSNotFound;
        BOOL ended = [action rangeOfString:@"end"].location != NSNotFound || [action rangeOfString:@"left"].location != NSNotFound;
        // a call of the other side's that this account never joined ended unanswered: a missed call here, as in the app
        BOOL theirs = m.senderPk.length && ![m.senderPk isEqualToString:[SHSettings userId] ?: @""];
        BOOL unanswered = ended && theirs && [call[@"did_join"] isKindOfClass:[NSNumber class]] && ![call[@"did_join"] boolValue];
        BOOL missed = unanswered || [words rangeOfString:@"miss"].location != NSNotFound || [words rangeOfString:@"unanswered"].location != NSNotFound
                   || [words rangeOfString:@"declin"].location != NSNotFound;
        m.systemRow = YES;
        m.missedCall = missed;
        m.callId = SHStr(call[@"vc_id"]);
        m.callStarted = !ended && !missed && [action rangeOfString:@"start"].location != NSNotFound;
        if (missed) m.placeholderText = audio ? L(@"Missed call") : L(@"Missed video call");
        else if ([action rangeOfString:@"end"].location != NSNotFound || [action rangeOfString:@"left"].location != NSNotFound)
            m.placeholderText = audio ? L(@"Call ended") : L(@"Video call ended");
        else if ([action rangeOfString:@"start"].location != NSNotFound || [action rangeOfString:@"join"].location != NSNotFound)
            m.placeholderText = audio ? L(@"Call started") : L(@"Video call started");
        else m.placeholderText = SHStr(call[@"description"]) ?: (audio ? L(@"Call") : L(@"Video call"));
        // how long it took: call_duration, else end - start (in the units of the times: s, ms or µs)
        NSTimeInterval seconds = SHDbl(call[@"call_duration"]) ?: SHDbl(call[@"duration"]);
        if (seconds > 36000) seconds /= 1000;   // (milliseconds)
        double start = SHDbl(call[@"call_start_time"]), end = SHDbl(call[@"call_end_time"]);
        if (seconds <= 0 && start > 0 && end > start) {
            seconds = end - start;
            if (start > 1e14) seconds /= 1e6; else if (start > 1e11) seconds /= 1e3;
        }
        if (seconds >= 1 && ended && !missed)
            m.placeholderText = [NSString stringWithFormat:@"%@, %d:%02d", m.placeholderText, (int)seconds / 60, (int)seconds % 60];
        // (debug builds: what a call carries, once per item, so its other forms can be taught)
        static NSMutableSet *loggedCalls;
        if (!loggedCalls) loggedCalls = [NSMutableSet set];
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        if (m.pk.length && ![loggedCalls containsObject:m.pk] && [[NSFileManager defaultManager] fileExistsAtPath:[docs stringByAppendingPathComponent:@"debug"]]) {
            [loggedCalls addObject:m.pk];
            SHLog(@"DMITEM call action=%@ desc=%@ did_join=%@ duration=%@ start=%@ end=%@ theirs=%d -> %@", action, SHStr(call[@"description"]) ?: @"-",
                  SHStr(call[@"did_join"]) ?: @"-", SHStr(call[@"call_duration"]) ?: @"-", SHStr(call[@"call_start_time"]) ?: @"-",
                  SHStr(call[@"call_end_time"]) ?: @"-", theirs, m.placeholderText);
        }
    } else if ([m.type isEqualToString:@"action_log"]) {
        m.placeholderText = SHStr(SHDict(d[@"action_log"])[@"description"]) ?: @"";
        m.systemRow = m.placeholderText.length > 0;
    } else {
        m.placeholderText = SHStr(d[@"text"]) ?: L(@"Unsupported message");
        // (debug builds: which kind it was and what it carries, so the next form Instagram invents can be taught)
        static int debugOn = -1;
        if (debugOn < 0) {
            NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            debugOn = [[NSFileManager defaultManager] fileExistsAtPath:[docs stringByAppendingPathComponent:@"debug"]] ? 1 : 0;
        }
        if (debugOn) SHLog(@"DMITEM unknown type=%@ keys=%@", m.type, [[d allKeys] componentsJoinedByString:@","]);
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
    // a call is one line, as in the app: its start is left out once its end (or the missed call) is listed too
    NSMutableSet *finishedCalls = [NSMutableSet set];
    for (SHDirectMessage *m in messages) if (m.callId.length && !m.callStarted) [finishedCalls addObject:m.callId];
    if (finishedCalls.count) {
        [messages removeObjectsAtIndexes:[messages indexesOfObjectsPassingTest:^BOOL(SHDirectMessage *m, NSUInteger i, BOOL *stop) {
            return m.callStarted && m.callId.length && [finishedCalls containsObject:m.callId];
        }]];
    }
    t.messages = messages;

    SHDirectMessage *last = [messages firstObject];
    t.lastText = last.text.length ? last.text : (last.placeholderText ?: @"");
    t.lastActivity = last.timestamp;
    t.unread = SHInt(d[@"read_state"]) != 0;

    // how far each one has read: {"<pk>": {"item_id": …, "timestamp": "<microseconds>"}}
    NSMutableDictionary *seen = [NSMutableDictionary dictionary];
    NSDictionary *lastSeen = SHDict(d[@"last_seen_at"]);
    for (id pk in lastSeen) {
        NSTimeInterval ts = SHDbl(SHDict(lastSeen[pk])[@"timestamp"]);
        if (ts > 1e14) ts /= 1e6;
        if (ts > 0 && SHStr(pk).length) seen[SHStr(pk)] = [NSDate dateWithTimeIntervalSince1970:ts];
    }
    t.lastSeenAt = seen;
    return t;
}

@end
