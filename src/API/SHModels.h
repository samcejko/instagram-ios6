#import <Foundation/Foundation.h>

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
+ (instancetype)fromJSON:(NSDictionary *)json;
@end

@interface SHMediaImage : NSObject
@property (nonatomic, copy) NSString *url;
@property (nonatomic) NSInteger width;
@property (nonatomic) NSInteger height;
+ (instancetype)bestFromCandidates:(NSArray *)candidates;
@end

@interface SHPost : NSObject
@property (nonatomic, copy) NSString *pk;
@property (nonatomic, copy) NSString *code;
@property (nonatomic) NSInteger mediaType;
@property (nonatomic, strong) SHUser *user;
@property (nonatomic, strong) SHMediaImage *image;
@property (nonatomic, copy) NSString *videoURL;
@property (nonatomic) NSTimeInterval videoDuration;
@property (nonatomic, copy) NSString *captionText;
@property (nonatomic) NSInteger likeCount;
@property (nonatomic) NSInteger commentCount;
@property (nonatomic) BOOL hasLiked;
@property (nonatomic) BOOL saved;
@property (nonatomic, strong) NSDate *takenAt;
@property (nonatomic, strong) NSArray *carouselMedia;
+ (instancetype)fromJSON:(NSDictionary *)json;
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
+ (instancetype)fromJSON:(NSDictionary *)json;
@end

@interface SHStoryReel : NSObject
@property (nonatomic, strong) SHUser *user;
@property (nonatomic, strong) NSArray *items;
@property (nonatomic) BOOL seen;
+ (instancetype)fromJSON:(NSDictionary *)json;
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
+ (instancetype)fromJSON:(NSDictionary *)json;
@end
