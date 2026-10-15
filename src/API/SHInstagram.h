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
typedef void (^SHThreadsCompletion)(NSArray *threads, NSString *cursor, NSError *error);
typedef void (^SHThreadCompletion)(SHDirectThread *thread, NSString *cursor, NSError *error);
typedef void (^SHMediaCompletion)(SHPost *post, NSError *error);
typedef void (^SHNewsCompletion)(NSArray *stories, NSError *error);
typedef void (^SHChallengeCompletion)(NSString *stepName, BOOL needsMethodChoice, NSError *error);

@interface SHInstagram : NSObject

+ (SHHTTPTask *)loginWithUsername:(NSString *)username password:(NSString *)password
                      completion:(void (^)(SHUser *user, NSString *twoFactorId, NSError *error))completion;

+ (SHHTTPTask *)twoFactorLoginWithIdentifier:(NSString *)identifier code:(NSString *)code
                                  completion:(SHLoginCompletion)completion;

// Checkpoint / challenge flow: after a login that returns SHErrorChallenge, and whenever a live session is stopped
// with challenge_required (SHHTTPChallengeRequiredNotification keeps the challenge path here once registered).
+ (void)registerChallengeObserver;
+ (BOOL)hasPendingChallenge;
+ (NSDictionary *)challengeStepData;   // step_data of the current step: masked "email"/"phone_number", "contact_point"
+ (SHHTTPTask *)challengeFetchWithCompletion:(SHChallengeCompletion)completion;      // GET: learn the current step
+ (SHHTTPTask *)challengeSelectMethod:(NSInteger)choice completion:(SHChallengeCompletion)completion;  // 1=email, 0=SMS
+ (SHHTTPTask *)challengeSubmitCode:(NSString *)code completion:(SHLoginCompletion)completion;

// Password-free connectivity probe: fetches the pre-login key sync and reports what came back.
+ (SHHTTPTask *)probeConnectivityWithCompletion:(void (^)(BOOL ok, NSString *detail, NSError *error))completion;

// Password-free self-test of the enc_password pipeline: encrypts a throwaway string with the real pubkey and
// checks the output is a well-formed #PWD_INSTAGRAM:4 blob (nothing is sent to Instagram). Verifies the RSA-OAEP
// (SHA-1) + AES-GCM path runs on-device without falling back to plaintext.
+ (SHHTTPTask *)encryptionSelfTestWithCompletion:(void (^)(BOOL ok, NSString *detail))completion;

// Password-free login-format probe: sends ONE /accounts/login/ request with a NON-EXISTENT username and the
// throwaway string as the password (no real account, no real credential). The server's reply shows how far the
// request got: "invalid_user" / a bad-password reply means Instagram accepted our request format and reached the
// credential check (so only real credentials remain); a format/signature error means there is still a request bug.
+ (SHHTTPTask *)loginFormatProbeWithCompletion:(void (^)(NSString *detail))completion;

+ (SHHTTPTask *)timelineFeedWithMaxId:(NSString *)maxId completion:(SHFeedCompletion)completion;

// What the first page of these lists was the last time (kept on disk): shown at once on the next start while the
// network freshens it. nil when nothing was kept; no cursor is given (the fresh page brings one).
+ (void)cachedTimelineWithCompletion:(SHFeedCompletion)completion;
+ (void)cachedExploreWithCompletion:(SHFeedCompletion)completion;
+ (void)cachedReelsWithCompletion:(SHFeedCompletion)completion;
+ (void)cachedNewsWithCompletion:(SHNewsCompletion)completion;
+ (void)cachedDirectInboxWithCompletion:(SHThreadsCompletion)completion;
+ (void)clearResponseCache;

+ (SHHTTPTask *)userInfoByUsername:(NSString *)username completion:(SHUserCompletion)completion;
+ (SHHTTPTask *)userInfoByPk:(NSString *)pk completion:(SHUserCompletion)completion;
+ (SHHTTPTask *)currentUserWithCompletion:(SHUserCompletion)completion;
+ (SHHTTPTask *)userFeedForPk:(NSString *)pk maxId:(NSString *)maxId completion:(SHFeedCompletion)completion;

// Followers / following lists and post likers (SHUser arrays, paginated by maxId).
+ (SHHTTPTask *)followersForPk:(NSString *)pk maxId:(NSString *)maxId query:(NSString *)query
                    completion:(void (^)(NSArray *users, NSString *nextMaxId, NSError *error))completion;
+ (SHHTTPTask *)followingForPk:(NSString *)pk maxId:(NSString *)maxId query:(NSString *)query
                    completion:(void (^)(NSArray *users, NSString *nextMaxId, NSError *error))completion;
+ (SHHTTPTask *)likersForPost:(NSString *)mediaPk completion:(SHSearchCompletion)completion;

// A single post by its numeric pk (used to resolve activity items and shortcodes).
+ (SHHTTPTask *)mediaInfo:(NSString *)mediaPk completion:(SHMediaCompletion)completion;

// Explore grid and the activity ("news") inbox.
+ (SHHTTPTask *)exploreWithMaxId:(NSString *)maxId completion:(SHFeedCompletion)completion;
+ (SHHTTPTask *)reelsWithMaxId:(NSString *)maxId completion:(SHFeedCompletion)completion;   // clips/discover
+ (SHHTTPTask *)newsInboxWithCompletion:(SHNewsCompletion)completion;

// Saved posts (bookmarks).
+ (SHHTTPTask *)savedFeedWithMaxId:(NSString *)maxId completion:(SHFeedCompletion)completion;
+ (SHHTTPTask *)savePost:(NSString *)mediaPk completion:(SHActionCompletion)completion;
+ (SHHTTPTask *)unsavePost:(NSString *)mediaPk completion:(SHActionCompletion)completion;

// Direct messages.
+ (SHHTTPTask *)directInboxWithCursor:(NSString *)cursor completion:(SHThreadsCompletion)completion;
+ (SHHTTPTask *)directThread:(NSString *)threadId cursor:(NSString *)cursor completion:(SHThreadCompletion)completion;
+ (SHHTTPTask *)sendDirectText:(NSString *)text toThread:(NSString *)threadId completion:(SHActionCompletion)completion;
// The same to a thread or, without one, to a person (Instagram finds or opens the one-to-one thread); answers the thread.
+ (SHHTTPTask *)sendDirectText:(NSString *)text toThread:(NSString *)threadId orUser:(NSString *)userPk
                    completion:(void (^)(BOOL ok, NSString *threadId, NSError *error))completion;
// A post shared into a chat (the paper plane under a post).
+ (SHHTTPTask *)sharePost:(SHPost *)post toThread:(NSString *)threadId orUser:(NSString *)userPk
               completion:(void (^)(BOOL ok, NSString *threadId, NSError *error))completion;
// A photo (JPEG) and a voice message (AAC in MP4, with its levels 0-1 ten times a second) into a chat.
+ (SHHTTPTask *)sendDirectPhoto:(NSData *)jpeg toThread:(NSString *)threadId completion:(SHActionCompletion)completion;
+ (SHHTTPTask *)sendDirectVoice:(NSData *)audio duration:(NSTimeInterval)duration waveform:(NSArray *)waveform
                       toThread:(NSString *)threadId completion:(SHActionCompletion)completion;

// Requests: people asking to follow this private account (answered with approve / ignore), and message requests
// (the pending inbox, accepted or hidden). The count of message requests comes with the inbox's first page.
+ (SHHTTPTask *)pendingFollowRequestsWithCompletion:(void (^)(NSArray *users, NSError *error))completion;
+ (SHHTTPTask *)answerFollowRequest:(NSString *)userPk approve:(BOOL)approve completion:(SHActionCompletion)completion;
+ (SHHTTPTask *)pendingDirectInboxWithCompletion:(SHThreadsCompletion)completion;
+ (SHHTTPTask *)answerMessageRequest:(NSString *)threadId accept:(BOOL)accept completion:(SHActionCompletion)completion;
+ (NSInteger)pendingMessageRequestCount;

// A tag's posts (its page) and tags matching a search (NSDictionary: "name", "count" = the number of posts).
+ (SHHTTPTask *)hashtagFeed:(NSString *)tag maxId:(NSString *)maxId completion:(SHFeedCompletion)completion;
+ (SHHTTPTask *)searchHashtags:(NSString *)query completion:(void (^)(NSArray *tags, NSError *error))completion;

+ (SHHTTPTask *)storiesTrayWithCompletion:(SHStoriesCompletion)completion;
+ (SHHTTPTask *)storiesForUserIds:(NSArray *)userIds completion:(SHStoriesCompletion)completion;
// Fetches the stories of the tray's circles that came without them (one request) and answers only the circles
// that have a story to show.
+ (SHHTTPTask *)fillStoryReels:(NSArray *)reels completion:(void (^)(NSArray *viewable))completion;
// Tells Instagram these stories of the reel were seen (the person sees the view, as with the app).
+ (SHHTTPTask *)markStoryItems:(NSArray *)items ofReel:(SHStoryReel *)reel completion:(SHActionCompletion)completion;

+ (SHHTTPTask *)likePost:(NSString *)mediaPk completion:(SHActionCompletion)completion;
+ (SHHTTPTask *)unlikePost:(NSString *)mediaPk completion:(SHActionCompletion)completion;

+ (SHHTTPTask *)commentsForPost:(NSString *)mediaPk minId:(NSString *)minId completion:(SHCommentsCompletion)completion;
+ (SHHTTPTask *)postComment:(NSString *)text onPost:(NSString *)mediaPk completion:(SHActionCompletion)completion;

+ (SHHTTPTask *)searchUsers:(NSString *)query completion:(SHSearchCompletion)completion;

+ (SHHTTPTask *)followUser:(NSString *)pk completion:(SHActionCompletion)completion;
+ (SHHTTPTask *)unfollowUser:(NSString *)pk completion:(SHActionCompletion)completion;
// The same with the relationship Instagram reports back (a private account turns a follow into a request).
+ (SHHTTPTask *)setFollowing:(BOOL)follow user:(NSString *)pk completion:(void (^)(BOOL following, BOOL requested, NSError *error))completion;
+ (SHHTTPTask *)friendshipWithUser:(NSString *)pk completion:(void (^)(BOOL following, BOOL requested, NSError *error))completion;

+ (SHHTTPTask *)logoutWithCompletion:(SHActionCompletion)completion;

@end
