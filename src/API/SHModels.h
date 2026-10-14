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
