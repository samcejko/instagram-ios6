#import <Foundation/Foundation.h>

typedef void (^SHHTTPCompletion)(NSInteger status, NSData *body, NSDictionary *headers, NSError *error);
typedef void (^SHJSONCompletion)(id json, NSInteger status, NSError *error);

// Posted on the main thread when any reply says {"message":"challenge_required"} (Instagram stopped the session
// for a security check). userInfo: "path" = challenge.api_path (or url) when the reply named one, "json" = the body.
extern NSString * const SHHTTPChallengeRequiredNotification;

// A running request of SHHTTP. After -cancel the completion block is never called.
@interface SHHTTPTask : NSObject
@property (atomic, readonly) BOOL isCancelled;
@property (atomic, copy) dispatch_block_t cancelBlock;   // for chained requests: called by -cancel (once)
- (void)cancel;
@end

// Convenience layer over SHHTTPRequest for API calls: redirects are followed, GET requests are tried a second
// time after a network error, completion blocks run on the main thread.
@interface SHHTTP : NSObject

+ (SHHTTPTask *)request:(NSString *)method url:(NSString *)url headers:(NSDictionary *)headers body:(NSData *)body
                retries:(NSInteger)retries completion:(SHHTTPCompletion)completion;

+ (SHHTTPTask *)get:(NSString *)url headers:(NSDictionary *)headers completion:(SHHTTPCompletion)completion;

// JSON answers. `error` is set for network errors, for statuses >= 400 (code = the status, message from the body
// when it has one) and for bodies that are not JSON; `json` is passed even with an error when the body parsed.
+ (SHHTTPTask *)getJSON:(NSString *)url headers:(NSDictionary *)headers completion:(SHJSONCompletion)completion;
+ (SHHTTPTask *)postJSON:(NSString *)url headers:(NSDictionary *)headers object:(id)object retries:(NSInteger)retries
              completion:(SHJSONCompletion)completion;
+ (SHHTTPTask *)postForm:(NSString *)url fields:(NSDictionary *)fields completion:(SHJSONCompletion)completion;
// The human-readable message in an error reply ({"message":…}, {"error_description":…}, …), or nil.
+ (NSString *)messageFromErrorJSON:(id)json;
+ (SHHTTPTask *)postForm:(NSString *)url headers:(NSDictionary *)headers fields:(NSDictionary *)fields completion:(SHJSONCompletion)completion;

@end
