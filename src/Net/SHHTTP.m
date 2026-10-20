#import "SHLegacyCollections.h"
#import "SHHTTP.h"
#import "SHHTTPRequest.h"
#import "SHSettings.h"
#import "SHUtils.h"
#import "SHCommon.h"

static const NSInteger SHMaxRedirects = 5;

NSString * const SHHTTPChallengeRequiredNotification = @"SHHTTPChallengeRequiredNotification";
NSString * const SHHTTPLoginRequiredNotification = @"SHHTTPLoginRequiredNotification";

// A completion that also gets the body already parsed as JSON (parsed on the network thread, not the main one).
typedef void (^SHHTTPParsedCompletion)(NSInteger status, NSData *body, id json, NSDictionary *headers, NSError *error);

// Debug builds log every request with where its time went (the "debug" file in Documents, read once).
static BOOL SHNetLogging(void)
{
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        on = [[NSFileManager defaultManager] fileExistsAtPath:[[SHUtils documentsPath] stringByAppendingPathComponent:@"debug"]];
    });
    return on;
}

// An error reply that is Instagram's checkpoint ({"message":"challenge_required","challenge":{"api_path":…}}).
// Every call of a stopped session answers this way, so the body is looked at once here, centrally.
static NSDictionary *SHChallengeInReply(NSInteger status, NSData *body, id parsed)
{
    if (status < 400 || !body.length || body.length > 8192) return nil;
    static const char marker[] = "challenge_required";
    if (![body rangeOfData:[NSData dataWithBytes:marker length:sizeof(marker) - 1] options:0 range:NSMakeRange(0, body.length)].length) return nil;
    NSDictionary *d = SHDict(parsed ?: [SHUtils JSONObjectFromData:body]);
    return [SHStr([d objectForKey:@"message"]) isEqualToString:@"challenge_required"] ? d : nil;
}

// Instagram's "this session is not valid" ({"message":"login_required"}, HTTP 403 as a rule, any 4xx counts), from
// its own API only.
static NSDictionary *SHLoginRequiredInReply(NSURL *url, NSInteger status, NSData *body, id parsed)
{
    if (status < 400 || status >= 500 || !body.length || body.length > 8192) return nil;
    if (![[url.host lowercaseString] hasSuffix:@"instagram.com"]) return nil;
    static const char marker[] = "login_required";
    if (![body rangeOfData:[NSData dataWithBytes:marker length:sizeof(marker) - 1] options:0 range:NSMakeRange(0, body.length)].length) return nil;
    NSDictionary *d = SHDict(parsed ?: [SHUtils JSONObjectFromData:body]);
    return [SHStr([d objectForKey:@"message"]) isEqualToString:@"login_required"] ? d : nil;
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
       hops:(NSInteger)hops retries:(NSInteger)retries parseJSON:(BOOL)parseJSON completion:(SHHTTPParsedCompletion)completion
{
    SHHTTPRequest *r = [[SHHTTPRequest alloc] initWithMethod:method URL:url];
    r.headers = headers;
    r.body = body;
    r.connectTimeout = 15;
    r.readTimeout = 30;
    r.verifyTLS = [SHSettings verifyTLS];
    __weak SHHTTPRequest *weakRequest = r;
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    r.onComplete = ^(NSError *error) {
        SHHTTPRequest *request = weakRequest;
        if (task.isCancelled) return;
        NSInteger status = request.statusCode;
        NSDictionary *responseHeaders = request.responseHeaders;
        if (!error && status >= 300 && status < 400 && status != 304 && hops < SHMaxRedirects) {
            NSString *location = [responseHeaders objectForKey:@"location"];
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
                        SHLegacyDictionarySet(trimmed, key, [headers objectForKey:key]);
                    }
                    nextHeaders = trimmed;
                }
                [self run:task method:toGet ? @"GET" : method url:next headers:nextHeaders body:toGet ? nil : body
                     hops:hops + 1 retries:retries parseJSON:parseJSON completion:completion];
                return;
            }
        }
        if (error && retries > 0 && error.code != SHErrorCancelled && error.code != SHErrorCertificate) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                if (task.isCancelled) return;
                [self run:task method:method url:url headers:headers body:body hops:hops retries:retries - 1 parseJSON:parseJSON completion:completion];
            });
            return;
        }
        NSData *responseBody = request.responseBody;
        // JSON is parsed here, on the network thread: an explore page is hundreds of kB, a visible stall on the main one
        CFAbsoluteTime parseStart = CFAbsoluteTimeGetCurrent();
        id json = (parseJSON && !error && responseBody.length) ? [SHUtils JSONObjectFromData:responseBody] : nil;
        CFAbsoluteTime parseEnd = CFAbsoluteTimeGetCurrent();
        NSDictionary *challenge = error ? nil : SHChallengeInReply(status, responseBody, json);
        NSDictionary *loggedOut = error ? nil : SHLoginRequiredInReply(url, status, responseBody, json);
        if (SHNetLogging() && ![url.host hasPrefix:@"127."]) {
            NSString *path = url.path ?: @"";
            if (path.length > 48) path = [[path substringToIndex:48] stringByAppendingString:@"..."];
            SHLog(@"NET %5.0f ms %@ %@%@ %ld | %@ | %lld B -> %lu B parse %.0f ms%@", (parseEnd - started) * 1000, method, url.host, path,
                  (long)status, request.timingSummary ?: @"-", request.wireBytes, (unsigned long)responseBody.length,
                  (parseEnd - parseStart) * 1000, error ? [@" ERROR " stringByAppendingString:error.localizedDescription] : @"");
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (task.isCancelled) return;
            if (challenge) {
                NSDictionary *c = SHDict([challenge objectForKey:@"challenge"]);
                NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:challenge forKey:@"json"];
                NSString *path = SHStr([c objectForKey:@"api_path"]) ?: SHStr([c objectForKey:@"url"]);
                if (path.length) SHLegacyDictionarySet(info, @"path", path);
                [[NSNotificationCenter defaultCenter] postNotificationName:SHHTTPChallengeRequiredNotification object:nil userInfo:info];
            }
            if (loggedOut)
                [[NSNotificationCenter defaultCenter] postNotificationName:SHHTTPLoginRequiredNotification object:nil
                                                                  userInfo:@{ @"json": loggedOut, @"status": @(status) }];
            if (completion) completion(error ? 0 : status, responseBody, json, responseHeaders, error);
        });
    };
    task.request = r;
    if (task.isCancelled) return;
    [r start];
}

+ (SHHTTPTask *)start:(NSString *)method url:(NSString *)url headers:(NSDictionary *)headers body:(NSData *)body
              retries:(NSInteger)retries parseJSON:(BOOL)parseJSON completion:(SHHTTPParsedCompletion)completion
{
    SHHTTPTask *task = [[SHHTTPTask alloc] init];
    NSURL *u = url.length ? [NSURL URLWithString:url] : nil;
    if (!u.host.length) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (task.isCancelled) return;
            if (completion) completion(0, nil, nil, nil, SHMakeError(SHErrorNetwork, [NSString stringWithFormat:@"Bad address: %@", url ?: @""]));
        });
        return task;
    }
    [self run:task method:method.length ? [method uppercaseString] : @"GET" url:u headers:headers body:body hops:0 retries:retries
    parseJSON:parseJSON completion:completion];
    return task;
}

+ (SHHTTPTask *)request:(NSString *)method url:(NSString *)url headers:(NSDictionary *)headers body:(NSData *)body
                retries:(NSInteger)retries completion:(SHHTTPCompletion)completion
{
    return [self start:method url:url headers:headers body:body retries:retries parseJSON:NO
            completion:^(NSInteger status, NSData *responseBody, id json, NSDictionary *responseHeaders, NSError *error) {
        if (completion) completion(status, responseBody, responseHeaders, error);
    }];
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
        return SHStr([first objectForKey:@"error"]) ?: SHStr([first objectForKey:@"message"]);
    }
    NSString *message = SHStr([d objectForKey:@"message"]);
    if (!message.length) message = SHStr([d objectForKey:@"error_description"]);
    if (!message.length) message = SHStr([SHDict([SHArr([d objectForKey:@"errors"]) firstObject]) objectForKey:@"message"]);
    if (!message.length && [[d objectForKey:@"error"] isKindOfClass:[NSString class]]) message = [d objectForKey:@"error"];
    // Instagram's machine-readable reasons, in the user's words
    if ([message isEqualToString:@"challenge_required"] || [message isEqualToString:@"checkpoint_required"]) return L(@"Instagram wants to check it's you.");
    if ([message isEqualToString:@"login_required"]) return L(@"Your session expired. Please log in again.");
    return message.length ? message : nil;
}

+ (SHHTTPParsedCompletion)jsonHandler:(SHJSONCompletion)completion
{
    return ^(NSInteger status, NSData *body, id json, NSDictionary *headers, NSError *error) {
        if (!completion) return;
        if (error) { completion(nil, 0, error); return; }
        if (status >= 400) {
            NSString *message = [self messageFromErrorJSON:json] ?: [NSString stringWithFormat:L(@"Request failed (HTTP %ld)."), (long)status];
            BOOL challenge = [SHStr([SHDict(json) objectForKey:@"message"]) isEqualToString:@"challenge_required"];
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
    if (![h objectForKey:@"Accept"]) SHLegacyDictionarySet(h, @"Accept", @"application/json");
    return [self start:@"GET" url:url headers:h body:nil retries:1 parseJSON:YES completion:[self jsonHandler:completion]];
}

+ (SHHTTPTask *)postJSON:(NSString *)url headers:(NSDictionary *)headers object:(id)object retries:(NSInteger)retries
              completion:(SHJSONCompletion)completion
{
    NSMutableDictionary *h = [NSMutableDictionary dictionaryWithDictionary:headers ?: @{}];
    if (![h objectForKey:@"Accept"]) SHLegacyDictionarySet(h, @"Accept", @"application/json");
    if (![h objectForKey:@"Content-Type"]) SHLegacyDictionarySet(h, @"Content-Type", @"application/json");
    NSData *body = [SHUtils JSONDataFromObject:object] ?: [NSData data];
    return [self start:@"POST" url:url headers:h body:body retries:retries parseJSON:YES completion:[self jsonHandler:completion]];
}

+ (SHHTTPTask *)postForm:(NSString *)url headers:(NSDictionary *)headers fields:(NSDictionary *)fields completion:(SHJSONCompletion)completion
{
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSString *key in fields) {
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", [SHUtils urlEncode:key], [SHUtils urlEncode:[[fields objectForKey:key] description]]]];
    }
    NSData *body = [[pairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *h = [NSMutableDictionary dictionaryWithDictionary:headers ?: @{}];
    if (![h objectForKey:@"Content-Type"]) SHLegacyDictionarySet(h, @"Content-Type", @"application/x-www-form-urlencoded");
    if (![h objectForKey:@"Accept"]) SHLegacyDictionarySet(h, @"Accept", @"application/json");
    return [self start:@"POST" url:url headers:h body:body retries:0 parseJSON:YES completion:[self jsonHandler:completion]];
}

+ (SHHTTPTask *)postForm:(NSString *)url fields:(NSDictionary *)fields completion:(SHJSONCompletion)completion
{
    return [self postForm:url headers:nil fields:fields completion:completion];
}

@end
