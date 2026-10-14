#import <Foundation/Foundation.h>
#import "SHHTTP.h"
#import "SHModels.h"

typedef void (^SHLoginCompletion)(SHUser *user, NSError *error);
typedef void (^SHTwoFactorCompletion)(NSString *twoFactorId, NSString *method, NSError *error);
typedef void (^SHFeedCompletion)(NSArray *posts, NSString *nextMaxId, NSError *error);
typedef void (^SHUserCompletion)(SHUser *user, NSError *error);
typedef void (^SHStoriesCompletion)(NSArray *reels, NSError *error);
typedef void (^SHCommentsCompletion)(NSArray *comments, NSString *nextMinId, NSError *error);
typedef void (^SHSearchCompletion)(NSArray *users, NSError *error);
typedef void (^SHActionCompletion)(BOOL success, NSError *error);

@interface SHInstagram : NSObject

+ (SHHTTPTask *)loginWithUsername:(NSString *)username password:(NSString *)password
                      completion:(void (^)(SHUser *user, NSString *twoFactorId, NSError *error))completion;

+ (SHHTTPTask *)twoFactorLoginWithIdentifier:(NSString *)identifier code:(NSString *)code
                                  completion:(SHLoginCompletion)completion;

+ (SHHTTPTask *)timelineFeedWithMaxId:(NSString *)maxId completion:(SHFeedCompletion)completion;

+ (SHHTTPTask *)userInfoByUsername:(NSString *)username completion:(SHUserCompletion)completion;
+ (SHHTTPTask *)userInfoByPk:(NSString *)pk completion:(SHUserCompletion)completion;
+ (SHHTTPTask *)userFeedForPk:(NSString *)pk maxId:(NSString *)maxId completion:(SHFeedCompletion)completion;

+ (SHHTTPTask *)storiesTrayWithCompletion:(SHStoriesCompletion)completion;
+ (SHHTTPTask *)storiesForUserIds:(NSArray *)userIds completion:(SHStoriesCompletion)completion;

+ (SHHTTPTask *)likePost:(NSString *)mediaPk completion:(SHActionCompletion)completion;
+ (SHHTTPTask *)unlikePost:(NSString *)mediaPk completion:(SHActionCompletion)completion;

+ (SHHTTPTask *)commentsForPost:(NSString *)mediaPk minId:(NSString *)minId completion:(SHCommentsCompletion)completion;
+ (SHHTTPTask *)postComment:(NSString *)text onPost:(NSString *)mediaPk completion:(SHActionCompletion)completion;

+ (SHHTTPTask *)searchUsers:(NSString *)query completion:(SHSearchCompletion)completion;

+ (SHHTTPTask *)followUser:(NSString *)pk completion:(SHActionCompletion)completion;
+ (SHHTTPTask *)unfollowUser:(NSString *)pk completion:(SHActionCompletion)completion;

+ (SHHTTPTask *)logoutWithCompletion:(SHActionCompletion)completion;

@end
