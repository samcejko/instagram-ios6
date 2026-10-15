#import <Foundation/Foundation.h>

@class UIImage;

@interface SHUser : NSObject
@property (nonatomic, copy) NSString *pk;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *fullName;
@property (nonatomic, copy) NSString *biography;
@property (nonatomic, copy) NSString *profilePicURL;
@property (nonatomic) NSInteger followerCount;
@property (nonatomic) NSInteger followingCount;
@property (nonatomic) NSInteger mediaCount;
@property (nonatomic) BOOL isPrivate;
@property (nonatomic) BOOL isVerified;
@property (nonatomic) BOOL friendshipFollowing;
@property (nonatomic) BOOL friendshipFollowedBy;
@property (nonatomic) BOOL friendshipRequested;     // a follow request to a private account is pending
+ (instancetype)fromJSON:(NSDictionary *)json;
@end

@interface SHMediaImage : NSObject
@property (nonatomic, copy) NSString *url;
@property (nonatomic) NSInteger width;
@property (nonatomic) NSInteger height;
+ (instancetype)bestFromCandidates:(NSArray *)candidates;                       // the largest
// The smallest candidate at least `minWidth` wide (the largest when none is): an iPad 2 should not pull a
// 1080 px JPEG for a 56 px avatar or a 250 px grid thumbnail.
+ (instancetype)candidateFromCandidates:(NSArray *)candidates minWidth:(NSInteger)minWidth;
@end

@interface SHPost : NSObject
@property (nonatomic, copy) NSString *pk;
@property (nonatomic, copy) NSString *code;
@property (nonatomic) NSInteger mediaType;
@property (nonatomic, strong) SHUser *user;
@property (nonatomic, strong) SHMediaImage *image;        // the largest version (post detail)
@property (nonatomic, strong) SHMediaImage *mediumImage;  // ~640 px (feed cells)
@property (nonatomic, strong) SHMediaImage *thumbImage;   // ~320 px (grids, DM shares)
@property (nonatomic, copy) NSString *videoURL;
@property (nonatomic) NSTimeInterval videoDuration;
@property (nonatomic, copy) NSString *captionText;
@property (nonatomic) NSInteger likeCount;
@property (nonatomic) NSInteger commentCount;
@property (nonatomic) BOOL hasLiked;
@property (nonatomic) BOOL saved;
@property (nonatomic, strong) NSDate *takenAt;
@property (nonatomic, strong) NSArray *carouselMedia;
@property (nonatomic, strong) NSArray *userTags;          // SHUserTag: the people tagged on the photo
+ (instancetype)fromJSON:(NSDictionary *)json;
@end

// A person tagged on a photo, at a point of it (0-1 across and down).
@interface SHUserTag : NSObject
@property (nonatomic, strong) SHUser *user;
@property (nonatomic) double x;
@property (nonatomic) double y;
@end

@interface SHComment : NSObject
@property (nonatomic, copy) NSString *pk;
@property (nonatomic, strong) SHUser *user;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) NSDate *createdAt;
@property (nonatomic) NSInteger likeCount;
+ (instancetype)fromJSON:(NSDictionary *)json;
@end

@interface SHStoryItem : NSObject
@property (nonatomic, copy) NSString *pk;
@property (nonatomic) NSInteger mediaType;
@property (nonatomic, strong) SHMediaImage *image;
@property (nonatomic, copy) NSString *videoURL;
@property (nonatomic) NSTimeInterval videoDuration;
@property (nonatomic, strong) NSDate *takenAt;
@property (nonatomic) NSTimeInterval expiringAt;
@property (nonatomic, strong) NSArray *mentions;          // SHStoryMention: the "@name" stickers on it
+ (instancetype)fromJSON:(NSDictionary *)json;
@end

// A mention sticker on a story: where it sits (its centre, 0-1 of the picture), how big and turned it is.
@interface SHStoryMention : NSObject
@property (nonatomic, strong) SHUser *user;
@property (nonatomic) double x, y, width, height, rotation;
@end

// One person's stories. "Seen" means every one of them has been looked at (the ring turns grey); how far the viewer
// got is kept as the time the newest seen story was posted, by Instagram and on this device.
// A highlight (stories kept on a profile, under a title and a cover) is a reel too; its id is "highlight:<number>".
@interface SHStoryReel : NSObject
@property (nonatomic, strong) SHUser *user;
@property (nonatomic, strong) NSArray *items;
@property (nonatomic, copy) NSString *reelId;            // the user's pk for stories, "highlight:…" for a highlight
@property (nonatomic, readonly) BOOL isHighlight;
@property (nonatomic, copy) NSString *title;             // a highlight's name
@property (nonatomic, copy) NSString *coverURL;          // a highlight's round cover
@property (nonatomic) NSInteger mediaCount;
@property (nonatomic) BOOL fromChat;                     // a photo or video of a chat shown full screen, not stories
@property (nonatomic, readonly) BOOL tracksSeen;         // a person's own stories (the ring, Instagram's view list)
@property (nonatomic) BOOL seen;
@property (nonatomic) NSTimeInterval latestReelMedia;   // when the newest story was posted (unix time)
@property (nonatomic) NSTimeInterval seenUpTo;          // when the newest story already seen was posted
+ (instancetype)fromJSON:(NSDictionary *)json;
- (void)noteSeenItem:(SHStoryItem *)item;   // a story was looked at (also remembered on this device)
- (void)applyRememberedSeen;                // what this device remembers (a tray from the server can lag behind)
- (NSUInteger)firstUnseenIndex;             // where to start: the first story not seen yet (0 when all are)
@end

// One item in the Activity ("news") tab: someone liked/commented/followed, with a short line of text.
@interface SHNewsStory : NSObject
@property (nonatomic, copy) NSString *text;             // "alice started following you"
@property (nonatomic, strong) NSDate *timestamp;
@property (nonatomic, copy) NSString *profilePicURL;    // the actor's avatar
@property (nonatomic, copy) NSString *mediaThumbURL;    // the related post's thumbnail, when any
@property (nonatomic, copy) NSString *mediaPk;          // the related post, when any
@property (nonatomic, copy) NSString *userPk;           // the actor, when the link is to a profile
@property (nonatomic, copy) NSString *username;
@property (nonatomic, strong) NSArray *requestUsers;    // the pinned "Follow requests" row: SHUser who asked (else nil)
+ (instancetype)fromJSON:(NSDictionary *)json;
@end

// One message inside a Direct thread.
@interface SHDirectMessage : NSObject
@property (nonatomic, copy) NSString *pk;               // item_id
@property (nonatomic, copy) NSString *type;             // "text", "media", "like", "media_share", ...
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *senderPk;
@property (nonatomic, strong) NSDate *timestamp;
@property (nonatomic, copy) NSString *previewURL;       // a thumbnail for media/shared items
@property (nonatomic, copy) NSString *placeholderText;  // a label for items we cannot render ("Shared a post")
@property (nonatomic, copy) NSString *audioURL;         // voice messages: the audio file to play
@property (nonatomic) NSTimeInterval audioDuration;
@property (nonatomic, strong) SHPost *sharedPost;       // media_share / clip: the post, to open it on tap
@property (nonatomic, copy) NSString *targetURL;        // the newer "xma" shares: the link a tap opens (instagram.com/p/…)
@property (nonatomic, copy) NSString *shareTitle;       // …and whose post, reel or story it is
@property (nonatomic, copy) NSString *videoURL;         // a video sent directly
@property (nonatomic, strong) UIImage *localImage;      // a photo just sent from here, shown until the thread reloads
@property (nonatomic) BOOL sending;                     // on its way (drawn faded)
// A photo or video from the chat's camera ("raven_media") meant to be opened on purpose: view_mode "once" or
// "replayable" ("permanent" ones are shown like any picture). The picture is there until it was seen.
@property (nonatomic) BOOL ephemeral;
@property (nonatomic, copy) NSString *viewMode;
@property (nonatomic, copy) NSString *ephemeralURL;     // the picture to open (nil once seen or gone)
@property (nonatomic) BOOL mediaIsVideo;
// A line of the chat's history rather than a message (a call, "liked a message"): drawn centred, as iOS 6 Messages
// drew its times. A missed call is drawn red.
@property (nonatomic) BOOL systemRow;
@property (nonatomic) BOOL missedCall;
+ (BOOL)ephemeralOpened:(NSString *)pk;                // opened on this device already
+ (void)noteEphemeralOpened:(NSString *)pk;
+ (instancetype)fromJSON:(NSDictionary *)json;
@end

// A Direct conversation.
@interface SHDirectThread : NSObject
@property (nonatomic, copy) NSString *threadId;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) NSArray *users;           // SHUser, the other participants
@property (nonatomic, strong) NSArray *messages;        // SHDirectMessage, newest first as returned
@property (nonatomic, copy) NSString *lastText;         // a preview line for the inbox
@property (nonatomic, strong) NSDate *lastActivity;
@property (nonatomic) BOOL unread;
@property (nonatomic, strong) NSDictionary *lastSeenAt;   // user pk -> when they last read the thread (NSDate), me too
+ (instancetype)fromJSON:(NSDictionary *)json;
@end
