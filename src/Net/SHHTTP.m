#import "SHHTTP.h"
#import "SHHTTPRequest.h"
#import "SHSettings.h"
#import "SHUtils.h"
#import "SHCommon.h"

static const NSInteger SHMaxRedirects = 5;

NSString * const SHHTTPChallengeRequiredNotification = @"SHHTTPChallengeRequiredNotification";

// An error reply that is Instagram's checkpoint ({"message":"challenge_required","challenge":{"api_path":…}}).
// Every call of a stopped session answers this way, so the body is looked at once here, centrally.
static NSDictionary *SHChallengeInReply(NSInteger status, NSData *body)
{
    if (status < 400 || !body.length || body.length > 8192) return nil;
    static const char marker[] = "challenge_required";
    if (![body rangeOfData:[NSData dataWithBytes:marker length:sizeof(marker) - 1] options:0 range:NSMakeRange(0, body.length)].length) return nil;
    NSDictionary *d = SHDict([SHUtils JSONObjectFromData:body]);
    return [SHStr(d[@"message"]) isEqualToString:@"challenge_required"] ? d : nil;
}

@interface SHHTTPTask ()
@property (atomic, strong) SHHTTPRequest *request;
@property (atomic) BOOL isCancelled;
@end

@implementation SHHTTPTask

- (void)cancel
{
    if (self.isCancelled) return;
    self.isCancelled = YES;
    [self.request cancel];
    dispatch_block_t block = self.cancelBlock;
    self.cancelBlock = nil;
    if (block) block();
}

@end

@implementation SHHTTP

+ (void)run:(SHHTTPTask *)task method:(NSString *)method url:(NSURL *)url headers:(NSDictionary *)headers body:(NSData *)body
       hops:(NSInteger)hops retries:(NSInteger)retries completion:(SHHTTPCompletion)completion
{
    SHHTTPRequest *r = [[SHHTTPRequest alloc] initWithMethod:method URL:url];
    r.headers = headers;
    r.body = body;
    r.connectTimeout = 15;
    r.readTimeout = 30;
    r.verifyTLS = [SHSettings verifyTLS];
    __weak SHHTTPRequest *weakRequest = r;
    r.onComplete = ^(NSError *error) {
        SHHTTPRequest *request = weakRequest;
        if (task.isCancelled) return;
        NSInteger status = request.statusCode;
        NSDictionary *responseHeaders = request.responseHeaders;
        if (!error && status >= 300 && status < 400 && status != 304 && hops < SHMaxRedirects) {
            NSString *location = responseHeaders[@"location"];
            NSURL *next = location.length ? [[NSURL URLWithString:location relativeToURL:url] absoluteURL] : nil;
            if (next.host.length) {
                BOOL safe = [method isEqualToString:@"GET"] || [method isEqualToString:@"HEAD"];
                BOOL toGet = status == 303 || ((status == 301 || status == 302) && !safe);
                NSDictionary *nextHeaders = headers;
                if (![[next.host lowercaseString] isEqualToString:[url.host lowercaseString]]) {
                    // credentials stay with the host they were meant for
                    NSMutableDictionary *trimmed = [NSMutableDictionary dictionary];
                    for (NSString *key in headers) {
                        NSString *lower = [key lowercaseString];
                        if ([lower isEqualToString:@"authorization"] || [lower isEqualToString:@"client-id"]) continue;
                        trimmed[key] = headers[key];
                    }
                    nextHeaders = trimmed;
                }
                [self run:task method:toGet ? @"GET" : method url:next headers:nextHeaders body:toGet ? nil : body
                     hops:hops + 1 retries:retries completion:completion];
                return;
            }
        }
        if (error && retries > 0 && error.code != SHErrorCancelled && error.code != SHErrorCertificate) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                if (task.isCancelled) return;
                [self run:task method:method url:url headers:headers body:body hops:hops retries:retries - 1 completion:completion];
            });
            return;
        }
        NSData *responseBody = request.responseBody;
        NSDictionary *challenge = error ? nil : SHChallengeInReply(status, responseBody);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (task.isCancelled) return;
            if (challenge) {
                NSDictionary *c = SHDict(challenge[@"challenge"]);
                NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:challenge forKey:@"json"];
                NSString *path = SHStr(c[@"api_path"]) ?: SHStr(c[@"url"]);
                if (path.length) info[@"path"] = path;
                [[NSNotificationCenter defaultCenter] postNotificationName:SHHTTPChallengeRequiredNotification object:nil userInfo:info];
            }
            if (completion) completion(error ? 0 : status, responseBody, responseHeaders, error);
        });
    };
    task.request = r;
    if (task.isCancelled) return;
    [r start];
}

+ (SHHTTPTask *)request:(NSString *)method url:(NSString *)url headers:(NSDictionary *)headers body:(NSData *)body
                retries:(NSInteger)retries completion:(SHHTTPCompletion)completion
{
    SHHTTPTask *task = [[SHHTTPTask alloc] init];
    NSURL *u = url.length ? [NSURL URLWithString:url] : nil;
    if (!u.host.length) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (task.isCancelled) return;
            if (completion) completion(0, nil, nil, SHMakeError(SHErrorNetwork, [NSString stringWithFormat:@"Bad address: %@", url ?: @""]));
        });
        return task;
    }
    [self run:task method:method.length ? [method uppercaseString] : @"GET" url:u headers:headers body:body hops:0 retries:retries completion:completion];
    return task;
}

+ (SHHTTPTask *)get:(NSString *)url headers:(NSDictionary *)headers completion:(SHHTTPCompletion)completion
{
    return [self request:@"GET" url:url headers:headers body:nil retries:1 completion:completion];
}

// What an error body says: {"message": ...}, {"error": ..., "message": ...}, {"error_description": ...}, {"errors": [{"message": ...}]}
+ (NSString *)messageFromErrorJSON:(id)json
{
    NSDictionary *d = SHDict(json);
    if (!d) {
        NSDictionary *first = SHDict([SHArr(json) firstObject]);
        return SHStr(first[@"error"]) ?: SHStr(first[@"message"]);
    }
    NSString *message = SHStr(d[@"message"]);
    if (!message.length) message = SHStr(d[@"error_description"]);
    if (!message.length) message = SHStr(SHDict([SHArr(d[@"errors"]) firstObject])[@"message"]);
    if (!message.length && [d[@"error"] isKindOfClass:[NSString class]]) message = d[@"error"];
    // Instagram's machine-readable reasons, in the user's words
    if ([message isEqualToString:@"challenge_required"] || [message isEqualToString:@"checkpoint_required"]) return L(@"Instagram wants to check it's you.");
    if ([message isEqualToString:@"login_required"]) return L(@"Your session expired. Please log in again.");
    return message.length ? message : nil;
}

+ (SHHTTPCompletion)jsonHandler:(SHJSONCompletion)completion
{
    return ^(NSInteger status, NSData *body, NSDictionary *headers, NSError *error) {
        if (!completion) return;
        if (error) { completion(nil, 0, error); return; }
        id json = [SHUtils JSONObjectFromData:body];
        if (status >= 400) {
            NSString *message = [self messageFromErrorJSON:json] ?: [NSString stringWithFormat:L(@"Request failed (HTTP %ld)."), (long)status];
            BOOL challenge = [SHStr(SHDict(json)[@"message"]) isEqualToString:@"challenge_required"];
            completion(json, status, SHMakeError(challenge ? SHErrorChallenge : status, message));
            return;
        }
        if (!json && body.length) {
            completion(nil, status, SHMakeError(SHErrorBadResponse, L(@"Unexpected response format.")));
            return;
        }
        completion(json, status, nil);
    };
}

+ (SHHTTPTask *)getJSON:(NSString *)url headers:(NSDictionary *)headers completion:(SHJSONCompletion)completion
{
    NSMutableDictionary *h = [NSMutableDictionary dictionaryWithDictionary:headers ?: @{}];
    if (!h[@"Accept"]) h[@"Accept"] = @"application/json";
    return [self request:@"GET" url:url headers:h body:nil retries:1 completion:[self jsonHandler:completion]];
}

+ (SHHTTPTask *)postJSON:(NSString *)url headers:(NSDictionary *)headers object:(id)object retries:(NSInteger)retries
              completion:(SHJSONCompletion)completion
{
    NSMutableDictionary *h = [NSMutableDictionary dictionaryWithDictionary:headers ?: @{}];
    if (!h[@"Accept"]) h[@"Accept"] = @"application/json";
    if (!h[@"Content-Type"]) h[@"Content-Type"] = @"application/json";
    NSData *body = [SHUtils JSONDataFromObject:object] ?: [NSData data];
    return [self request:@"POST" url:url headers:h body:body retries:retries completion:[self jsonHandler:completion]];
}

+ (SHHTTPTask *)postForm:(NSString *)url headers:(NSDictionary *)headers fields:(NSDictionary *)fields completion:(SHJSONCompletion)completion
{
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSString *key in fields) {
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", [SHUtils urlEncode:key], [SHUtils urlEncode:[fields[key] description]]]];
    }
    NSData *body = [[pairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *h = [NSMutableDictionary dictionaryWithDictionary:headers ?: @{}];
    if (!h[@"Content-Type"]) h[@"Content-Type"] = @"application/x-www-form-urlencoded";
    if (!h[@"Accept"]) h[@"Accept"] = @"application/json";
    return [self request:@"POST" url:url headers:h body:body retries:0 completion:[self jsonHandler:completion]];
}

+ (SHHTTPTask *)postForm:(NSString *)url fields:(NSDictionary *)fields completion:(SHJSONCompletion)completion
{
    return [self postForm:url headers:nil fields:fields completion:completion];
}

@end
