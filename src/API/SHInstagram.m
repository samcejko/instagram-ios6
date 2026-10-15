#import "SHInstagram.h"
#import "SHSettings.h"
#import "SHUtils.h"
#import "SHCommon.h"

#include "mbedtls/pk.h"
#include "mbedtls/rsa.h"
#include "mbedtls/gcm.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/base64.h"

@interface SHInstagram ()
+ (void)setChallengePath:(NSString *)path;
+ (NSString *)challengeURL;
+ (SHHTTPTask *)fetchEncryptionKeyWithCompletion:(void (^)(NSString *pubKey, NSInteger keyId, NSError *error))completion;
@end

static NSString * const SHApiBase      = @"https://i.instagram.com/api/v1";
static NSString * const SHAppId        = @"567067343352427";
// The spoofed app version must stay recent or Instagram refuses the login with error_type "needs_upgrade"
// ("Your version of Instagram is out of date"). These are instagrapi's current default Android profile
// (449.0.0.52.84, Android 14/API 34); bump them together when the server starts asking for an upgrade again.
static NSString * const SHAppVersion   = @"449.0.0.52.84";
static NSString * const SHVersionCode  = @"1079242191";
static NSString * const SHBloksVersion = @"799db3e387d7a21a19c72918b8698b6cd28a1516ade363792c100ed45a0f9f0b";
static NSString * const SHSignatureKey = @"SIGNATURE";

#pragma mark - User-Agent and headers

static NSString *SHUserAgent(void)
{
    return [NSString stringWithFormat:
        @"Instagram %@ Android (34/14; 640dpi; 1440x3120; OnePlus; LE2123; OnePlus9Pro; qcom; en_US; %@)",
        SHAppVersion, SHVersionCode];
}

static NSDictionary *SHCommonHeaders(void)
{
    NSMutableDictionary *h = [NSMutableDictionary dictionary];
    h[@"User-Agent"]            = SHUserAgent();
    h[@"X-IG-App-ID"]           = SHAppId;
    h[@"X-IG-Device-ID"]        = [SHSettings deviceId];
    h[@"X-IG-Android-ID"]       = [SHSettings androidId];
    h[@"X-IG-Connection-Type"]  = @"WIFI";
    h[@"X-IG-Capabilities"]     = @"3brTvx0=";
    h[@"X-Bloks-Version-Id"]    = SHBloksVersion;
    h[@"Accept-Language"]       = @"en-US";
    h[@"Accept"]                = @"application/json";
    return h;
}

static NSDictionary *SHAuthHeaders(void)
{
    NSMutableDictionary *h = [SHCommonHeaders() mutableCopy];
    NSString *token = [SHSettings sessionToken];
    if (token.length) h[@"Authorization"] = [@"Bearer IGT:2:" stringByAppendingString:token];
    NSString *csrf = [SHSettings csrfToken];
    if (csrf.length) h[@"X-CSRFToken"] = csrf;
    NSString *claim = [SHSettings wwwClaim];
    h[@"X-IG-WWW-Claim"] = claim.length ? claim : @"0";
    NSString *uid = [SHSettings userId];
    if (uid.length) h[@"IG-U-DS-User-ID"] = uid;
    return h;
}

// jazoest = "2" + the sum of the byte values of the phone_id. Instagram checks it against phone_id on login.
static NSString *SHJazoest(NSString *phoneId)
{
    const char *p = [phoneId UTF8String] ?: "";
    NSInteger sum = 0;
    for (size_t i = 0; p[i]; i++) sum += (unsigned char)p[i];
    return [NSString stringWithFormat:@"2%ld", (long)sum];
}

#pragma mark - Signed body

static NSString *SHSignedBody(NSDictionary *params)
{
    NSData *json = [SHUtils JSONDataFromObject:params];
    NSString *jsonStr = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    return [NSString stringWithFormat:@"signed_body=%@.%@&ig_sig_key_version=4",
            SHSignatureKey, [SHUtils urlEncode:jsonStr]];
}

static NSData *SHSignedBodyData(NSDictionary *params)
{
    return [SHSignedBody(params) dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - Password encryption

static NSString *SHEncryptPassword(NSString *password, NSString *pubKeyBase64, NSInteger keyId)
{
    if (!password.length || !pubKeyBase64.length) return nil;

    NSData *keyData = [SHUtils base64Decode:pubKeyBase64];
    if (!keyData.length) return nil;
    // Instagram sends the key base64-encoded; decoded it is PEM text ("-----BEGIN PUBLIC KEY-----..."). mbedTLS's PEM
    // reader needs the buffer NUL-terminated with the NUL counted in the length (same as the CA bundle in SHTLSSocket).
    // Without it the parse fails, SHEncryptPassword returns nil and login silently falls back to the plaintext
    // password that Instagram rejects. (DER keys, which start with 0x30, are passed through unchanged.)
    NSMutableData *keyBuf = [keyData mutableCopy];
    BOOL isPEM = keyData.length >= 10 && memcmp(keyData.bytes, "-----BEGIN", 10) == 0;
    if (isPEM) { unsigned char zero = 0; [keyBuf appendBytes:&zero length:1]; }

    mbedtls_pk_context pk;
    mbedtls_pk_init(&pk);
    int ret = mbedtls_pk_parse_public_key(&pk, keyBuf.bytes, keyBuf.length);
    if (ret != 0) { mbedtls_pk_free(&pk); return nil; }

    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context ctr_drbg;
    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&ctr_drbg);
    ret = mbedtls_ctr_drbg_seed(&ctr_drbg, mbedtls_entropy_func, &entropy, NULL, 0);
    if (ret != 0) { mbedtls_pk_free(&pk); mbedtls_ctr_drbg_free(&ctr_drbg); mbedtls_entropy_free(&entropy); return nil; }

    unsigned char aesKey[32], iv[12];
    mbedtls_ctr_drbg_random(&ctr_drbg, aesKey, 32);
    mbedtls_ctr_drbg_random(&ctr_drbg, iv, 12);

    mbedtls_rsa_context *rsa = mbedtls_pk_rsa(pk);
    // Instagram wraps the AES session key with RSA **PKCS#1 v1.5**, not OAEP (instagrapi uses PKCS1_v1_5.new).
    // The padded block is the same 256 bytes either way, so the output *looks* right, but with OAEP the server
    // unpads to garbage, recovers the wrong AES key and reports a correct password as incorrect.
    mbedtls_rsa_set_padding(rsa, MBEDTLS_RSA_PKCS_V15, MBEDTLS_MD_NONE);
    size_t rsaLen = mbedtls_rsa_get_len(rsa);
    unsigned char *rsaOut = malloc(rsaLen);
    ret = mbedtls_rsa_rsaes_pkcs1_v15_encrypt(rsa, mbedtls_ctr_drbg_random, &ctr_drbg,
                                              32, aesKey, rsaOut);
    mbedtls_pk_free(&pk);
    if (ret != 0) { free(rsaOut); mbedtls_ctr_drbg_free(&ctr_drbg); mbedtls_entropy_free(&entropy); return nil; }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *timeStr = [NSString stringWithFormat:@"%lld", (long long)now];
    NSData *aad = [timeStr dataUsingEncoding:NSUTF8StringEncoding];

    const char *pwd = [password UTF8String];
    size_t pwdLen = strlen(pwd);
    unsigned char *aesOut = malloc(pwdLen);
    unsigned char tag[16];

    mbedtls_gcm_context gcm;
    mbedtls_gcm_init(&gcm);
    mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, aesKey, 256);
    ret = mbedtls_gcm_crypt_and_tag(&gcm, MBEDTLS_GCM_ENCRYPT, pwdLen,
                                     iv, 12, aad.bytes, aad.length,
                                     (unsigned char *)pwd, aesOut, 16, tag);
    mbedtls_gcm_free(&gcm);
    mbedtls_ctr_drbg_free(&ctr_drbg);
    mbedtls_entropy_free(&entropy);
    if (ret != 0) { free(rsaOut); free(aesOut); return nil; }

    size_t payloadLen = 2 + 12 + 2 + rsaLen + 16 + pwdLen;
    unsigned char *payload = malloc(payloadLen);
    size_t off = 0;
    payload[off++] = 1;
    payload[off++] = (unsigned char)keyId;
    memcpy(payload + off, iv, 12); off += 12;
    payload[off++] = (unsigned char)(rsaLen & 0xFF);
    payload[off++] = (unsigned char)((rsaLen >> 8) & 0xFF);
    memcpy(payload + off, rsaOut, rsaLen); off += rsaLen;
    memcpy(payload + off, tag, 16); off += 16;
    memcpy(payload + off, aesOut, pwdLen); off += pwdLen;

    free(rsaOut);
    free(aesOut);

    NSString *b64 = [SHUtils base64Encode:[NSData dataWithBytesNoCopy:payload length:payloadLen freeWhenDone:YES]];
    return [NSString stringWithFormat:@"#PWD_INSTAGRAM:4:%@:%@", timeStr, b64];
}

#pragma mark - Response handling

static void SHSaveTokensFromHeaders(NSDictionary *headers)
{
    for (NSString *key in headers) {
        NSString *lower = [key lowercaseString];
        if ([lower isEqualToString:@"ig-set-authorization"]) {
            NSString *val = headers[key];
            if ([val hasPrefix:@"Bearer IGT:2:"]) {
                NSString *token = [val substringFromIndex:@"Bearer IGT:2:".length];
                if (token.length) {
                    [SHSettings setSessionToken:token];
                    // The token is base64(JSON) with ds_user_id/sessionid; pull the user id so the account loads
                    // without a separate request (the CAA login response carries no logged_in_user object).
                    NSDictionary *claims = SHDict([SHUtils JSONObjectFromData:[SHUtils base64Decode:token]]);
                    NSString *uid = SHStr(claims[@"ds_user_id"]);
                    if (uid.length) [SHSettings setUserId:uid];
                }
            }
        }
        if ([lower isEqualToString:@"x-ig-set-www-claim"]) {
            NSString *claim = headers[key];
            // The server hands back "0" before login and a real "hmac....." claim afterwards; keep the real one,
            // which every subsequent request must echo in X-IG-WWW-Claim or it is rejected with login_required.
            if (claim.length && ![claim isEqualToString:@"0"]) [SHSettings setWwwClaim:claim];
        }
    }
}

static NSString *SHExtractCSRF(NSDictionary *headers)
{
    for (NSString *key in headers) {
        if ([[key lowercaseString] isEqualToString:@"set-cookie"]) {
            NSString *val = headers[key];
            NSRange r = [val rangeOfString:@"csrftoken="];
            if (r.location != NSNotFound) {
                NSString *rest = [val substringFromIndex:r.location + r.length];
                NSString *token = [[rest componentsSeparatedByString:@";"] firstObject];
                return token.length ? token : nil;
            }
        }
    }
    return nil;
}

// Best-effort pull of a string value for `key` out of a bloks/JSON blob, handling both "key":"val" and the
// backslash-escaped \"key\":\"val\" bloks encodes. nil when not found.
static NSString *SHExtractJSONString(NSString *body, NSString *key)
{
    if (!body.length || !key.length) return nil;
    NSArray *patterns = @[ [NSString stringWithFormat:@"\"%@\":\"", key], [NSString stringWithFormat:@"\\\"%@\\\":\\\"", key] ];
    for (NSString *pat in patterns) {
        NSRange r = [body rangeOfString:pat];
        if (r.location == NSNotFound) continue;
        NSUInteger i = r.location + r.length;
        NSMutableString *out = [NSMutableString string];
        while (i < body.length) {
            unichar c = [body characterAtIndex:i];
            if (c == '\\') { i += 2; continue; }
            if (c == '"') break;
            [out appendFormat:@"%C", c];
            i++;
        }
        if (out.length) return out;
    }
    return nil;
}

// The run of allowed characters at `start`. Used to lift tokens out of the heavily-escaped bloks body.
static NSString *SHReadRun(NSString *s, NSUInteger start, NSCharacterSet *allowed)
{
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = start; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (![allowed characterIsMember:c]) break;
        [out appendFormat:@"%C", c];
    }
    return out;
}

// On a successful CAA login the session arrives INSIDE the bloks payload (not in an ig-set-authorization header)
// as an embedded "IG-Set-Authorization: Bearer IGT:2:<b64>" string. Lift the base64 token out (SHSettings stores
// the part after "Bearer IGT:2:"). nil when the body has no token (a failure / 2FA / challenge screen).
static NSString *SHExtractBearerFromBody(NSString *body)
{
    NSRange r = [body rangeOfString:@"Bearer IGT:2:"];
    if (r.location == NSNotFound) return nil;
    NSCharacterSet *tok = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-"];
    NSString *t = SHReadRun(body, r.location + r.length, tok);
    return t.length > 20 ? t : nil;
}

// The www-claim ("hmac....") is embedded in the same block; keep it for later requests.
static NSString *SHExtractClaimFromBody(NSString *body)
{
    NSRange r = [body rangeOfString:@"x-ig-set-www-claim" options:NSCaseInsensitiveSearch];
    if (r.location == NSNotFound) return nil;
    NSRange h = [body rangeOfString:@"hmac." options:0 range:NSMakeRange(r.location, MIN((NSUInteger)220, body.length - r.location))];
    if (h.location == NSNotFound) return nil;
    NSCharacterSet *claim = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"];
    NSString *c = SHReadRun(body, h.location, claim);
    return c.length > 5 ? c : nil;
}

// A readable reason out of a bloks login response (the body is a UI-flow blob; string matching is what the
// reference libraries use too). nil when nothing recognisable is found.
static NSString *SHExtractBloksError(NSString *body)
{
    if (!body.length) return nil;
    if ([body rangeOfString:@"password you entered is incorrect" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [body rangeOfString:@"incorrect password" options:NSCaseInsensitiveSearch].location != NSNotFound)
        return L(@"The password you entered is incorrect.");
    if ([body rangeOfString:@"find your account" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [body rangeOfString:@"doesn't belong" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [body rangeOfString:@"No account found" options:NSCaseInsensitiveSearch].location != NSNotFound)
        return L(@"That username doesn't belong to an account.");
    if ([body rangeOfString:@"out of date" options:NSCaseInsensitiveSearch].location != NSNotFound)
        return L(@"Your version of Instagram is out of date.");
    return nil;
}

#pragma mark - Response cache

// The first page of the main lists (timeline, explore, activity, inbox) is kept on disk, so that the next start
// shows them at once while the network only freshens them. Kept per account, dropped at logout.
static NSString *SHResponseCacheDirectory(void)
{
    return [[SHUtils cachesPath] stringByAppendingPathComponent:@"responses"];
}

static NSString *SHResponseCachePath(NSString *key)
{
    NSString *account = [SHSettings userId].length ? [SHSettings userId] : @"0";
    return [SHResponseCacheDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.json", account, key]];
}

static void SHResponseCacheStore(NSString *key, id json)
{
    if (![json isKindOfClass:[NSDictionary class]]) return;
    NSString *path = SHResponseCachePath(key);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        @autoreleasepool {
            [[NSFileManager defaultManager] createDirectoryAtPath:SHResponseCacheDirectory() withIntermediateDirectories:YES attributes:nil error:NULL];
            NSData *data = [SHUtils JSONDataFromObject:json];
            if (data.length) [data writeToFile:path atomically:YES];
        }
    });
}

// Reads and parses off the main thread; `use` runs on the main thread, with nil when nothing was kept.
static void SHResponseCacheLoad(NSString *key, void (^use)(NSDictionary *json))
{
    NSString *path = SHResponseCachePath(key);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        @autoreleasepool {
            NSData *data = [NSData dataWithContentsOfFile:path];
            NSDictionary *json = SHDict(data.length ? [SHUtils JSONObjectFromData:data] : nil);
            dispatch_async(dispatch_get_main_queue(), ^{ use(json); });
        }
    });
}

#pragma mark - Parsing of the main lists (shared by the network and the cache)

static NSArray *SHParseTimeline(NSDictionary *d)
{
    NSMutableArray *posts = [NSMutableArray array];
    for (id item in SHArr(d[@"feed_items"]) ?: SHArr(d[@"items"])) {
        NSDictionary *node = SHDict(item);
        SHPost *p = [SHPost fromJSON:SHDict(node[@"media_or_ad"]) ?: node];
        if (p && p.pk.length) [posts addObject:p];
    }
    return posts;
}

static void SHCollectMedia(id node, NSMutableArray *out, NSMutableSet *seen);

static NSArray *SHParseExplore(NSDictionary *d)
{
    NSMutableArray *posts = [NSMutableArray array];
    SHCollectMedia(d[@"sectional_items"] ?: d[@"items"] ?: d, posts, [NSMutableSet set]);
    return posts;
}

// The videos of a clips page: in "items" or, in the newer layout, in "items_with_ads" between the ads (left out).
static NSArray *SHParseReels(NSDictionary *d)
{
    NSMutableArray *all = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *key in @[ @"items", @"items_with_ads" ]) {
        for (id entry in SHArr(d[key])) {
            NSDictionary *e = SHDict(entry);
            NSDictionary *media = SHDict(e[@"media"]);
            if (e[@"ad"] || e[@"ad_id"] || media[@"ad_id"] || media[@"ad_action"] || e[@"dr_ad_type"]) continue;
            SHCollectMedia(e, all, seen);
        }
    }
    NSMutableArray *videos = [NSMutableArray array];
    for (SHPost *p in all) if (p.videoURL.length || p.mediaType == 2) [videos addObject:p];
    return videos;
}

static NSArray *SHParseNews(NSDictionary *d)
{
    NSMutableArray *stories = [NSMutableArray array];
    for (NSString *key in @[ @"new_stories", @"old_stories", @"stories" ]) {
        for (id s in SHArr(d[key])) { SHNewsStory *n = [SHNewsStory fromJSON:SHDict(s)]; if (n) [stories addObject:n]; }
    }
    return stories;
}

static NSArray *SHParseInbox(NSDictionary *json, NSString **cursor)
{
    NSDictionary *inbox = SHDict(json[@"inbox"]);
    NSMutableArray *threads = [NSMutableArray array];
    for (id t in SHArr(inbox[@"threads"])) {
        SHDirectThread *thread = [SHDirectThread fromJSON:SHDict(t)];
        if (thread.threadId.length) [threads addObject:thread];
    }
    if (cursor) *cursor = SHBool(inbox[@"has_older"]) ? SHStr(inbox[@"oldest_cursor"]) : nil;
    return threads;
}

#pragma mark - Login

@implementation SHInstagram

// Modern CAA / bloks login request. Instagram deprecated the plain /accounts/login/ endpoint (it answers
// "needs_upgrade"); this is the flow the current app uses. The session token still comes back in the
// ig-set-authorization response header, so the (un-signed) bloks body only needs scanning for errors/2FA/challenge.
+ (SHHTTPTask *)caaSendLoginRequest:(NSString *)username encPassword:(NSString *)encPassword
                         completion:(SHHTTPCompletion)completion
{
    NSString *deviceId = [SHSettings androidId];
    NSString *guid = [SHSettings deviceId];
    NSDictionary *clientInput = @{
        @"secure_family_device_id": @"",
        @"has_whatsapp_installed": @0,
        @"password": encPassword ?: @"",
        @"sso_enabled": @(YES),
        @"device_id": deviceId,
        @"login_attempt_count": @0,
        @"login_source": @"Login",
        @"is_platform_login": @0,
        @"fb_ig_device_id": @[],
        @"device_emails": @[],
        @"try_num": @1,
        @"lois_settings": @{ @"lois_token": @"", @"lara_override": @"" },
        @"event_flow": @"login_manual",
        @"event_step": @"home_page",
        @"headers_infra_flow_id": @"",
        @"openid_tokens": @{},
        @"contact_point": username ?: @"",
        @"encrypted_msisdn": @"",
        @"accounts_list": @[],
    };
    NSDictionary *serverParams = @{
        @"should_trigger_override_login_2fa_action": @0,
        @"is_from_logged_out": @0,
        @"should_trigger_override_login_success_action": @0,
        @"login_credential_type": @"none",
        @"server_login_source": @"login",
        @"waterfall_id": [[NSUUID UUID] UUIDString],
        @"login_source": @"Login",
        @"is_platform_login": @0,
        @"INTERNAL__latency_qpl_marker_id": @36707139,
        @"is_from_landing_page": @0,
        @"password_text_input_id": [guid stringByAppendingString:@":1"],
        @"is_from_empty_password": @0,
        @"is_from_msplit_fallback": @0,
        @"ar_event_source": @"login_home_page",
        @"qe_device_id": guid,
        @"username_text_input_id": [guid stringByAppendingString:@":0"],
        @"device_id": deviceId,
        @"reg_flow_source": @"login_home_native_integration_point",
        @"is_caa_perf_enabled": @1,
        @"credential_type": @"password",
        @"is_from_password_entry_page": @0,
        @"caller": @"gslr",
        @"family_device_id": guid,
        @"is_from_assistive_id": @0,
        @"access_flow_version": @"LOGIN_FLOW_V2",
        @"is_from_logged_in_switcher": @0,
    };
    NSString *paramsJSON = [[NSString alloc] initWithData:[SHUtils JSONDataFromObject:@{ @"client_input_params": clientInput, @"server_params": serverParams }] encoding:NSUTF8StringEncoding];
    NSString *bkJSON = [[NSString alloc] initWithData:[SHUtils JSONDataFromObject:@{ @"bloks_version": SHBloksVersion, @"styles_id": @"instagram" }] encoding:NSUTF8StringEncoding];

    NSMutableDictionary *h = [SHCommonHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";
    NSString *csrf = [SHSettings csrfToken];
    if (csrf.length) h[@"X-CSRFToken"] = csrf;

    NSString *bodyStr = [NSString stringWithFormat:@"params=%@&bk_client_context=%@&bloks_versioning_id=%@",
        [SHUtils urlEncode:paramsJSON], [SHUtils urlEncode:bkJSON], SHBloksVersion];
    NSString *url = [SHApiBase stringByAppendingString:@"/bloks/apps/com.bloks.www.bloks.caa.login.async.send_login_request/"];
    return [SHHTTP request:@"POST" url:url headers:h body:[bodyStr dataUsingEncoding:NSUTF8StringEncoding] retries:0 completion:completion];
}

+ (SHHTTPTask *)fetchEncryptionKeyWithCompletion:(void (^)(NSString *pubKey, NSInteger keyId, NSError *error))completion
{
    NSDictionary *params = @{
        @"id": [SHSettings deviceId],
        @"experiments": @"ig_android_fci_onboarding_friend_search,ig_android_device_detection_info_upload",
    };
    NSMutableDictionary *h = [SHCommonHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";

    return [SHHTTP request:@"POST" url:[SHApiBase stringByAppendingString:@"/qe/sync/"]
                   headers:h body:SHSignedBodyData(params) retries:1
                completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *error) {
        if (error) { completion(nil, 0, error); return; }
        NSString *csrf = SHExtractCSRF(headers);
        if (csrf) [SHSettings setCsrfToken:csrf];
        NSString *pubKey = nil;
        NSInteger keyId = 0;
        for (NSString *key in headers) {
            NSString *lower = [key lowercaseString];
            if ([lower isEqualToString:@"ig-set-password-encryption-pub-key"])
                pubKey = headers[key];
            if ([lower isEqualToString:@"ig-set-password-encryption-key-id"])
                keyId = [headers[key] integerValue];
        }
        completion(pubKey, keyId, nil);
    }];
}

+ (SHHTTPTask *)loginWithUsername:(NSString *)username password:(NSString *)password
                      completion:(void (^)(SHUser *user, NSString *twoFactorId, NSError *error))completion
{
    SHHTTPTask *task = [[SHHTTPTask alloc] init];
    [self fetchEncryptionKeyWithCompletion:^(NSString *pubKey, NSInteger keyId, NSError *error) {
        if (task.isCancelled) return;
        if (error) { completion(nil, nil, error); return; }

        NSString *encPassword = nil;
        if (pubKey.length) {
            encPassword = SHEncryptPassword(password, pubKey, keyId);
        }
        if (!encPassword) {
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            encPassword = [NSString stringWithFormat:@"#PWD_INSTAGRAM:0:%lld:%@", (long long)now, password];
        }

        SHHTTPTask *inner = [self caaSendLoginRequest:username encPassword:encPassword
            completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *loginErr) {
                NSString *newCsrf = SHExtractCSRF(headers);
                if (newCsrf) [SHSettings setCsrfToken:newCsrf];
                SHSaveTokensFromHeaders(headers);   // the token (and ds_user_id) arrive here on success

                // Diagnostic (debug builds only): dump the full server reply to a file and log the response header
                // names + content markers, so the real CAA flow can be reverse-engineered without ever logging the
                // password or the token value.
                if ([[NSFileManager defaultManager] fileExistsAtPath:[[SHUtils documentsPath] stringByAppendingPathComponent:@"debug"]]) {
                    NSString *dbg = body.length ? ([[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"") : @"";
                    NSMutableArray *hdrNames = [NSMutableArray array];
                    for (NSString *k in headers) [hdrNames addObject:[k lowercaseString]];
                    NSString *lc = [dbg lowercaseString];
                    SHLog(@"CAALOGIN HTTP %ld len=%lu headers=[%@]", (long)status, (unsigned long)dbg.length, [hdrNames componentsJoinedByString:@","]);
                    SHLog(@"CAALOGIN markers: 2fa=%d code=%d incorrect=%d checkpoint=%d challenge=%d bearer=%d sessionid=%d ds_user=%d success_action=%d 2fa_action=%d fallback_true=%d",
                        (int)([lc rangeOfString:@"two_factor"].location != NSNotFound || [lc rangeOfString:@"two step"].location != NSNotFound),
                        (int)([lc rangeOfString:@"security code"].location != NSNotFound || [lc rangeOfString:@"verification code"].location != NSNotFound),
                        (int)([lc rangeOfString:@"incorrect"].location != NSNotFound),
                        (int)([lc rangeOfString:@"checkpoint"].location != NSNotFound),
                        (int)([lc rangeOfString:@"challenge"].location != NSNotFound),
                        (int)([lc rangeOfString:@"bearer"].location != NSNotFound || [lc rangeOfString:@"igt:"].location != NSNotFound),
                        (int)([lc rangeOfString:@"sessionid"].location != NSNotFound),
                        (int)([lc rangeOfString:@"ds_user_id"].location != NSNotFound),
                        (int)([lc rangeOfString:@"override_login_success_action"].location != NSNotFound),
                        (int)([lc rangeOfString:@"override_login_2fa_action"].location != NSNotFound),
                        (int)([lc rangeOfString:@"fallback_triggered\":true"].location != NSNotFound));
                }

                NSString *bodyStr = body.length ? ([[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"") : @"";
                // A successful CAA login carries the session INSIDE the bloks payload (no ig-set-authorization
                // header), so lift the token / www-claim out of the body when the header path gave nothing.
                if (![SHSettings isLoggedIn]) {
                    NSString *tok = SHExtractBearerFromBody(bodyStr);
                    if (tok.length) {
                        [SHSettings setSessionToken:tok];
                        NSDictionary *claims = SHDict([SHUtils JSONObjectFromData:[SHUtils base64Decode:tok]]);
                        NSString *uid = SHStr(claims[@"ds_user_id"]);
                        if (uid.length) [SHSettings setUserId:uid];
                        NSString *claim = SHExtractClaimFromBody(bodyStr);
                        if (claim.length) [SHSettings setWwwClaim:claim];
                    }
                }

                if ([SHSettings isLoggedIn]) {
                    [SHSettings setUsername:username];
                    [SHSettings save];
                    completion(nil, nil, nil);      // signed in; the feed/profile load the account from the token
                    return;
                }

                if ([bodyStr rangeOfString:@"two_factor" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [bodyStr rangeOfString:@"two_step_verification" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    NSString *tfId = SHExtractJSONString(bodyStr, @"two_factor_identifier") ?: @"";
                    [SHSettings setUsername:username];
                    completion(nil, tfId, nil);
                    return;
                }
                if ([bodyStr rangeOfString:@"challenge" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    NSString *path = SHExtractJSONString(bodyStr, @"api_path");
                    if (path.length) [self setChallengePath:path];
                    completion(nil, nil, SHMakeError(SHErrorChallenge,
                        L(@"Instagram needs to verify it's you. A code will be sent to your e-mail or phone.")));
                    return;
                }
                NSString *msg = SHExtractBloksError(bodyStr) ?: (loginErr.localizedDescription ?: L(@"Login failed."));
                completion(nil, nil, SHMakeError(status ?: SHErrorAPI, msg));
            }];
        task.cancelBlock = ^{ [inner cancel]; };
    }];
    return task;
}

+ (SHHTTPTask *)twoFactorLoginWithIdentifier:(NSString *)identifier code:(NSString *)code
                                  completion:(SHLoginCompletion)completion
{
    NSDictionary *params = @{
        @"verification_code": code,
        @"two_factor_identifier": identifier,
        @"username": [SHSettings username].length ? [SHSettings username] : @"",
        @"guid": [SHSettings deviceId],
        @"device_id": [SHSettings androidId],
    };
    NSMutableDictionary *h = [SHCommonHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";
    NSString *csrf = [SHSettings csrfToken];
    if (csrf.length) h[@"X-CSRFToken"] = csrf;

    return [SHHTTP request:@"POST"
        url:[SHApiBase stringByAppendingString:@"/accounts/two_factor_login/"]
        headers:h body:SHSignedBodyData(params) retries:0
        completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *error) {
            NSString *newCsrf = SHExtractCSRF(headers);
            if (newCsrf) [SHSettings setCsrfToken:newCsrf];
            SHSaveTokensFromHeaders(headers);

            id json = body.length ? [SHUtils JSONObjectFromData:body] : nil;
            NSDictionary *d = SHDict(json);
            if (error || !SHBool(d[@"authenticated"])) {
                NSString *msg = SHStr(d[@"message"]) ?: (error.localizedDescription ?: L(@"Verification failed."));
                completion(nil, SHMakeError(status ?: SHErrorAPI, msg));
                return;
            }
            SHUser *user = [SHUser fromJSON:SHDict(d[@"logged_in_user"])];
            if (user) {
                [SHSettings setUserId:user.pk];
                [SHSettings setUsername:user.username];
                [SHSettings save];
            }
            completion(user, nil);
        }];
}

#pragma mark - Feed

+ (SHHTTPTask *)timelineFeedWithMaxId:(NSString *)maxId completion:(SHFeedCompletion)completion
{
    // The timeline is a POST (a GET returns HTTP 405); plain form body, not signed.
    NSMutableDictionary *h = [SHAuthHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";
    h[@"X-Ig-Nav-Chain"] = @"com.bloks.www.caa.login.login_homepage:com.bloks.www.caa.login.login_homepage:1:button:0";
    NSMutableDictionary *fields = [@{
        @"has_camera_permission": @"1",
        @"feed_view_info": @"[]",
        @"phone_id": [SHSettings phoneId],
        @"reason": maxId.length ? @"pagination" : @"cold_start_fetch",
        @"battery_level": @"100",
        @"timezone_offset": @"0",
        @"device_id": [SHSettings deviceId],
        @"request_id": [[NSUUID UUID] UUIDString],
        @"_uuid": [SHSettings deviceId],
        @"is_charging": @"1",
        @"will_sound_on": @"0",
        @"is_pull_to_refresh": @"0",
    } mutableCopy];
    if (maxId.length) fields[@"max_id"] = maxId;
    NSString *csrf = [SHSettings csrfToken];
    if (csrf.length) fields[@"_csrftoken"] = csrf;

    return [SHHTTP postForm:[SHApiBase stringByAppendingString:@"/feed/timeline/"] headers:h fields:fields
                 completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, nil, error); return; }
        NSDictionary *d = SHDict(json);
        NSArray *posts = SHParseTimeline(d);
        if (!maxId.length) SHResponseCacheStore(@"timeline", d);
        if ([[NSFileManager defaultManager] fileExistsAtPath:[[SHUtils documentsPath] stringByAppendingPathComponent:@"debug"]]) {
            SHLog(@"FEED status=%ld msg=%@ feed_items=%lu parsed=%lu more=%@", (long)status, SHStr(d[@"message"]) ?: @"-",
                  (unsigned long)(SHArr(d[@"feed_items"]) ?: SHArr(d[@"items"])).count, (unsigned long)posts.count,
                  SHStr(d[@"next_max_id"]).length ? @"yes" : @"no");
        }
        completion(posts, SHStr(d[@"next_max_id"]), nil);
    }];
}

+ (void)cachedTimelineWithCompletion:(SHFeedCompletion)completion
{
    SHResponseCacheLoad(@"timeline", ^(NSDictionary *json) { completion(json ? SHParseTimeline(json) : nil, nil, nil); });
}

+ (void)cachedExploreWithCompletion:(SHFeedCompletion)completion
{
    SHResponseCacheLoad(@"explore", ^(NSDictionary *json) { completion(json ? SHParseExplore(json) : nil, nil, nil); });
}

+ (void)cachedReelsWithCompletion:(SHFeedCompletion)completion
{
    SHResponseCacheLoad(@"reels", ^(NSDictionary *json) { completion(json ? SHParseReels(json) : nil, nil, nil); });
}

+ (void)cachedNewsWithCompletion:(SHNewsCompletion)completion
{
    SHResponseCacheLoad(@"news", ^(NSDictionary *json) { completion(json ? SHParseNews(json) : nil, nil); });
}

+ (void)cachedDirectInboxWithCompletion:(SHThreadsCompletion)completion
{
    SHResponseCacheLoad(@"inbox", ^(NSDictionary *json) { completion(json ? SHParseInbox(json, NULL) : nil, nil, nil); });
}

+ (void)clearResponseCache
{
    [[NSFileManager defaultManager] removeItemAtPath:SHResponseCacheDirectory() error:NULL];
}

#pragma mark - Users

// The mobile lookup gives the full user (counts, friendship_status); the web profile stands in when it fails.
+ (SHHTTPTask *)userInfoByUsername:(NSString *)username completion:(SHUserCompletion)completion
{
    NSString *url = [NSString stringWithFormat:@"%@/users/%@/usernameinfo/", SHApiBase, [SHUtils urlEncode:username]];
    return [SHHTTP getJSON:url headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        SHUser *user = [SHUser fromJSON:SHDict(SHDict(json)[@"user"])];
        if (user.pk.length && !error && status < 400) { completion(user, nil); return; }
        NSString *webUrl = [NSString stringWithFormat:@"%@/users/web_profile_info/?username=%@", SHApiBase, [SHUtils urlEncode:username]];
        [SHHTTP getJSON:webUrl headers:SHAuthHeaders() completion:^(id json2, NSInteger status2, NSError *error2) {
            if (error2) { completion(nil, error2); return; }
            NSDictionary *d = SHDict(json2);
            NSDictionary *userData = SHDict(SHDict(d[@"data"])[@"user"]) ?: SHDict(d[@"user"]);
            SHUser *webUser = [SHUser fromJSON:userData];
            if (!webUser.pk.length) { completion(nil, SHMakeError(SHErrorBadResponse, L(@"User not found."))); return; }
            completion(webUser, nil);
        }];
    }];
}

+ (SHHTTPTask *)userInfoByPk:(NSString *)pk completion:(SHUserCompletion)completion
{
    NSString *url = [NSString stringWithFormat:@"%@/users/%@/info/", SHApiBase, pk];
    return [SHHTTP getJSON:url headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, error); return; }
        SHUser *user = [SHUser fromJSON:SHDict(SHDict(json)[@"user"])];
        if (!user) { completion(nil, SHMakeError(SHErrorBadResponse, L(@"User not found."))); return; }
        completion(user, nil);
    }];
}

+ (SHHTTPTask *)userFeedForPk:(NSString *)pk maxId:(NSString *)maxId completion:(SHFeedCompletion)completion
{
    NSMutableString *url = [NSMutableString stringWithFormat:@"%@/feed/user/%@/", SHApiBase, pk];
    if (maxId.length) [url appendFormat:@"?max_id=%@", [SHUtils urlEncode:maxId]];
    return [SHHTTP getJSON:url headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, nil, error); return; }
        NSDictionary *d = SHDict(json);
        NSMutableArray *posts = [NSMutableArray array];
        for (NSDictionary *item in SHArr(d[@"items"])) {
            SHPost *p = [SHPost fromJSON:item];
            if (p && p.pk.length) [posts addObject:p];
        }
        completion(posts, SHStr(d[@"next_max_id"]), nil);
    }];
}

#pragma mark - Stories

+ (SHHTTPTask *)storiesTrayWithCompletion:(SHStoriesCompletion)completion
{
    NSString *url = [NSString stringWithFormat:@"%@/feed/reels_tray/", SHApiBase];
    return [SHHTTP getJSON:url headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSDictionary *d = SHDict(json);
        NSMutableArray *reels = [NSMutableArray array];
        NSMutableSet *people = [NSMutableSet set];
        NSUInteger withItems = 0;
        BOOL debug = [[NSFileManager defaultManager] fileExistsAtPath:[[SHUtils documentsPath] stringByAppendingPathComponent:@"debug"]];
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        for (id entry in SHArr(d[@"tray"])) {
            NSDictionary *tray = SHDict(entry);
            SHStoryReel *r = [SHStoryReel fromJSON:tray];
            if (debug) {
                // what the tray says about each circle (a circle without a story to show is the question)
                SHLog(@"TRAYREEL %@ type=%@ items=%lu media_count=%@ media_ids=%lu latest=%.0fh ago expires=%.0fh seen=%@ besties=%@ nux=%@",
                      r.user.username ?: @"?", SHStr(tray[@"reel_type"]) ?: @"-", (unsigned long)SHArr(tray[@"items"]).count,
                      SHStr(tray[@"media_count"]) ?: @"-", (unsigned long)SHArr(tray[@"media_ids"]).count,
                      SHDbl(tray[@"latest_reel_media"]) > 0 ? (now - SHDbl(tray[@"latest_reel_media"])) / 3600 : -1,
                      SHDbl(tray[@"expiring_at"]) > 0 ? (SHDbl(tray[@"expiring_at"]) - now) / 3600 : -1,
                      SHStr(tray[@"seen"]) ?: @"-", SHStr(tray[@"has_besties_media"]) ?: @"-", SHStr(tray[@"is_nux"]) ?: @"-");
            }
            // Not every circle is a story: for an account that follows few people Instagram fills the tray with
            // accounts it suggests following ("suggested_user": no story, nothing to open). Only reels stay; also
            // none that already ran out.
            if ([SHStr(tray[@"reel_type"]) isEqualToString:@"suggested_user"]) continue;
            // "highlight_rewind_reel" is a look back at someone's old highlights, a second circle next to their
            // stories (no latest_reel_media, never "seen"); what reels_media gives for the person is their stories,
            // so it would only show them twice. One circle per person, the stories one.
            if ([SHStr(tray[@"reel_type"]) hasPrefix:@"highlight"]) continue;
            if (SHDbl(tray[@"expiring_at"]) > 0 && SHDbl(tray[@"expiring_at"]) < now) continue;
            if (SHDbl(tray[@"latest_reel_media"]) > 0 && now - SHDbl(tray[@"latest_reel_media"]) > 26 * 3600) continue;
            if (r.user.pk.length && [people containsObject:r.user.pk]) continue;
            if (r && r.user) {
                if (r.user.pk.length) [people addObject:r.user.pk];
                [reels addObject:r];
                if (r.items.count) withItems++;
            }
        }
        if (debug) SHLog(@"TRAY status=%ld reels=%lu withItems=%lu", (long)status, (unsigned long)reels.count, (unsigned long)withItems);
        completion(reels, nil);
    }];
}

+ (SHHTTPTask *)storiesForUserIds:(NSArray *)userIds completion:(SHStoriesCompletion)completion
{
    // reels_media takes a SIGNED JSON body with user_ids as an array (a plain form with a comma list is rejected).
    NSMutableArray *ids = [NSMutableArray array];
    for (id uid in userIds) if (SHStr(uid).length) [ids addObject:SHStr(uid)];
    NSString *capabilities = @"[{\"name\":\"SUPPORTED_SDK_VERSIONS\",\"value\":\"108.0,109.0,110.0,111.0,112.0,113.0,114.0,115.0,116.0,117.0,118.0,119.0\"},"
                              "{\"name\":\"FACE_TRACKER_VERSION\",\"value\":\"14\"},{\"name\":\"segmentation\",\"value\":\"segmentation_enabled\"},"
                              "{\"name\":\"COMPRESSION\",\"value\":\"ETC2_COMPRESSION\"},{\"name\":\"world_tracker\",\"value\":\"world_tracker_enabled\"},"
                              "{\"name\":\"gyroscope\",\"value\":\"gyroscope_enabled\"}]";
    NSDictionary *params = @{ @"user_ids": ids, @"_uuid": [SHSettings deviceId], @"_csrftoken": [SHSettings csrfToken] ?: @"",
                              @"source": @"feed_timeline", @"supported_capabilities_new": capabilities };
    NSMutableDictionary *h = [SHAuthHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";

    return [SHHTTP request:@"POST" url:[NSString stringWithFormat:@"%@/feed/reels_media/", SHApiBase]
                   headers:h body:SHSignedBodyData(params) retries:0
                completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *error) {
        id json = body.length ? [SHUtils JSONObjectFromData:body] : nil;
        if ([[NSFileManager defaultManager] fileExistsAtPath:[[SHUtils documentsPath] stringByAppendingPathComponent:@"debug"]]) {
            id reelsNode = SHDict(json)[@"reels_media"] ?: SHDict(json)[@"reels"];
            id firstReel = [reelsNode isKindOfClass:[NSDictionary class]] ? [(NSDictionary *)reelsNode allValues].firstObject
                         : [reelsNode isKindOfClass:[NSArray class]] ? [(NSArray *)reelsNode firstObject] : nil;
            SHLog(@"STORIES ids=%@ status=%ld error=%@ keys=%@ reels=%@ n=%lu firstReelKeys=%@ items=%lu", [ids componentsJoinedByString:@","],
                  (long)status, error.localizedDescription ?: @"-", [[SHDict(json) allKeys] componentsJoinedByString:@","],
                  NSStringFromClass([reelsNode class]), (unsigned long)[reelsNode count],
                  [[SHDict(firstReel) allKeys] componentsJoinedByString:@","], (unsigned long)SHArr(SHDict(firstReel)[@"items"]).count);
        }
        if (error) { completion(nil, error); return; }
        if (status >= 400) { completion(nil, SHMakeError(status, [SHHTTP messageFromErrorJSON:json] ?: L(@"Couldn't load the story."))); return; }
        NSDictionary *d = SHDict(json);
        NSDictionary *reelsMedia = SHDict(d[@"reels_media"]) ?: SHDict(d[@"reels"]);
        NSMutableArray *reels = [NSMutableArray array];
        if ([reelsMedia isKindOfClass:[NSDictionary class]]) {
            for (NSString *key in reelsMedia) {
                SHStoryReel *r = [SHStoryReel fromJSON:SHDict(reelsMedia[key])];
                if (r) [reels addObject:r];
            }
        } else {
            for (NSDictionary *reel in SHArr(d[@"reels_media"]) ?: SHArr(d[@"reels"])) {
                SHStoryReel *r = [SHStoryReel fromJSON:reel];
                if (r) [reels addObject:r];
            }
        }
        if (reels.count == 0 && ids.count == 1) {   // reels_media answers {"reels":{}} for this account: ask per user
            [self userStoryFeed:ids[0] completion:completion];
            return;
        }
        completion(reels, nil);
    }];
}

// Tells Instagram which stories were looked at, as the app does (POST api/v2/media/seen/): the person sees the view,
// and the ring is grey on every device. One request for the stories seen of one person.
+ (SHHTTPTask *)markStoryItems:(NSArray *)items ofReel:(SHStoryReel *)reel completion:(SHActionCompletion)completion
{
    NSString *owner = reel.user.pk;
    NSMutableDictionary *seen = [NSMutableDictionary dictionary];
    long long now = (long long)[[NSDate date] timeIntervalSince1970];
    for (SHStoryItem *item in items) {
        if (!item.pk.length || !owner.length) continue;
        long long taken = (long long)[item.takenAt timeIntervalSince1970];
        seen[[NSString stringWithFormat:@"%@_%@_%@", item.pk, owner, owner]] = @[ [NSString stringWithFormat:@"%lld_%lld", taken, MAX(taken, now)] ];
    }
    if (!seen.count) { if (completion) completion(NO, nil); return nil; }
    NSDictionary *params = @{ @"_uuid": [SHSettings deviceId], @"_uid": [SHSettings userId] ?: @"", @"_csrftoken": [SHSettings csrfToken] ?: @"",
                              @"container_module": @"feed_timeline", @"reels": seen, @"reel_media_skipped": @{},
                              @"live_vods": @{}, @"live_vods_skipped": @{}, @"nuxes": @{}, @"nuxes_skipped": @{} };
    NSMutableDictionary *h = [SHAuthHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";
    NSString *v2 = [SHApiBase stringByReplacingOccurrencesOfString:@"/api/v1" withString:@"/api/v2"];
    return [SHHTTP request:@"POST" url:[v2 stringByAppendingString:@"/media/seen/?reel=1&live_vod=0"] headers:h body:SHSignedBodyData(params)
                   retries:0 completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *error) {
        BOOL ok = !error && status < 400;
        if ([[NSFileManager defaultManager] fileExistsAtPath:[[SHUtils documentsPath] stringByAppendingPathComponent:@"debug"]])
            SHLog(@"SEEN %@ items=%lu status=%ld %@", reel.user.username ?: @"?", (unsigned long)seen.count, (long)status,
                  error.localizedDescription ?: @"");
        if (completion) completion(ok, error);
    }];
}

// The circles of the tray carry their stories only for the first few. This asks for the rest in ONE request (as
// the app does when the tray shows up), puts what comes back into the tray's own reel objects, and answers the
// circles that have something to show. Instagram lists people in the tray whose stories it then does not give out
// (expired, hidden from this account); those are dropped, so a tap never opens onto nothing. One reel that came
// with its items goes along as a check: when even that one comes back empty the request itself failed, and the
// tray is answered unfiltered.
+ (SHHTTPTask *)fillStoryReels:(NSArray *)reels completion:(void (^)(NSArray *viewable))completion
{
    NSMutableArray *ids = [NSMutableArray array];
    SHStoryReel *control = nil;
    for (SHStoryReel *r in reels) {
        if (r.items.count) { if (!control && r.user.pk.length) control = r; continue; }
        if (r.user.pk.length && ids.count < 30) [ids addObject:r.user.pk];
    }
    if (!ids.count) { completion(reels); return nil; }
    if (control) [ids addObject:control.user.pk];
    return [self storiesForUserIds:ids completion:^(NSArray *fetched, NSError *error) {
        if (error) { completion(reels); return; }
        NSMutableDictionary *byPk = [NSMutableDictionary dictionary];
        for (SHStoryReel *f in fetched) if (f.user.pk.length && f.items.count) byPk[f.user.pk] = f;
        BOOL trustworthy = control ? byPk[control.user.pk] != nil : byPk.count > 0;
        if (!trustworthy) { completion(reels); return; }
        NSMutableArray *viewable = [NSMutableArray array];
        for (SHStoryReel *r in reels) {
            SHStoryReel *f = byPk[r.user.pk ?: @""];
            if (!r.items.count && f) r.items = f.items;
            if (r.items.count) [viewable addObject:r];
        }
        completion(viewable);
    }];
}

// The older per-user story endpoints, tried in turn: feed/user/{id}/story/ answers {"reel": …} (null without a
// story), feed/user/{id}/reel_media/ is the reel itself.
+ (SHHTTPTask *)userStoryFeed:(NSString *)userId completion:(SHStoriesCompletion)completion
{
    BOOL debug = [[NSFileManager defaultManager] fileExistsAtPath:[[SHUtils documentsPath] stringByAppendingPathComponent:@"debug"]];
    NSString *url = [NSString stringWithFormat:@"%@/feed/user/%@/story/", SHApiBase, userId];
    return [SHHTTP getJSON:url headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        NSDictionary *d = SHDict(json);
        SHStoryReel *r = [SHStoryReel fromJSON:SHDict(d[@"reel"])];
        if (debug) SHLog(@"USERSTORY %@ status=%ld error=%@ keys=%@ items=%lu", userId, (long)status, error.localizedDescription ?: @"-",
                         [[d allKeys] componentsJoinedByString:@","], (unsigned long)r.items.count);
        if (error) { completion(nil, error); return; }
        if (r.items.count) { completion(@[ r ], nil); return; }
        NSString *url2 = [NSString stringWithFormat:@"%@/feed/user/%@/reel_media/", SHApiBase, userId];
        [SHHTTP getJSON:url2 headers:SHAuthHeaders() completion:^(id json2, NSInteger status2, NSError *error2) {
            NSDictionary *d2 = SHDict(json2);
            SHStoryReel *r2 = [SHStoryReel fromJSON:d2];
            if (debug) SHLog(@"REELMEDIA %@ status=%ld error=%@ keys=%@ items=%lu", userId, (long)status2, error2.localizedDescription ?: @"-",
                             [[d2 allKeys] componentsJoinedByString:@","], (unsigned long)r2.items.count);
            if (error2) { completion(nil, error2); return; }
            completion(r2.items.count ? @[ r2 ] : @[], nil);
        }];
    }];
}

#pragma mark - Interactions

+ (SHHTTPTask *)likePost:(NSString *)mediaPk completion:(SHActionCompletion)completion
{
    NSDictionary *params = @{
        @"media_id": mediaPk,
        @"_uid": [SHSettings userId],
        @"_uuid": [SHSettings deviceId],
    };
    NSMutableDictionary *h = [SHAuthHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";
    return [SHHTTP request:@"POST"
        url:[NSString stringWithFormat:@"%@/media/%@/like/", SHApiBase, mediaPk]
        headers:h body:SHSignedBodyData(params) retries:0
        completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *error) {
            id json = body.length ? [SHUtils JSONObjectFromData:body] : nil;
            if (error) { completion(NO, error); return; }
            completion(SHStr(SHDict(json)[@"status"]) && [SHStr(SHDict(json)[@"status"]) isEqualToString:@"ok"], nil);
        }];
}

+ (SHHTTPTask *)unlikePost:(NSString *)mediaPk completion:(SHActionCompletion)completion
{
    NSDictionary *params = @{
        @"media_id": mediaPk,
        @"_uid": [SHSettings userId],
        @"_uuid": [SHSettings deviceId],
    };
    NSMutableDictionary *h = [SHAuthHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";
    return [SHHTTP request:@"POST"
        url:[NSString stringWithFormat:@"%@/media/%@/unlike/", SHApiBase, mediaPk]
        headers:h body:SHSignedBodyData(params) retries:0
        completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *error) {
            id json = body.length ? [SHUtils JSONObjectFromData:body] : nil;
            if (error) { completion(NO, error); return; }
            completion(SHStr(SHDict(json)[@"status"]) && [SHStr(SHDict(json)[@"status"]) isEqualToString:@"ok"], nil);
        }];
}

#pragma mark - Comments

+ (SHHTTPTask *)commentsForPost:(NSString *)mediaPk minId:(NSString *)minId completion:(SHCommentsCompletion)completion
{
    NSMutableString *url = [NSMutableString stringWithFormat:@"%@/media/%@/comments/", SHApiBase, mediaPk];
    if (minId.length) [url appendFormat:@"?min_id=%@", [SHUtils urlEncode:minId]];
    return [SHHTTP getJSON:url headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, nil, error); return; }
        NSDictionary *d = SHDict(json);
        NSMutableArray *comments = [NSMutableArray array];
        for (NSDictionary *item in SHArr(d[@"comments"])) {
            SHComment *c = [SHComment fromJSON:item];
            if (c) [comments addObject:c];
        }
        completion(comments, SHStr(d[@"next_min_id"]), nil);
    }];
}

+ (SHHTTPTask *)postComment:(NSString *)text onPost:(NSString *)mediaPk completion:(SHActionCompletion)completion
{
    NSDictionary *params = @{
        @"comment_text": text,
        @"_uid": [SHSettings userId],
        @"_uuid": [SHSettings deviceId],
    };
    NSMutableDictionary *h = [SHAuthHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";
    return [SHHTTP request:@"POST"
        url:[NSString stringWithFormat:@"%@/media/%@/comment/", SHApiBase, mediaPk]
        headers:h body:SHSignedBodyData(params) retries:0
        completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *error) {
            id json = body.length ? [SHUtils JSONObjectFromData:body] : nil;
            if (error) { completion(NO, error); return; }
            completion(SHStr(SHDict(json)[@"status"]) && [SHStr(SHDict(json)[@"status"]) isEqualToString:@"ok"], nil);
        }];
}

#pragma mark - Search

+ (SHHTTPTask *)searchUsers:(NSString *)query completion:(SHSearchCompletion)completion
{
    NSString *url = [NSString stringWithFormat:@"%@/users/search/?q=%@&count=30", SHApiBase, [SHUtils urlEncode:query]];
    return [SHHTTP getJSON:url headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSMutableArray *users = [NSMutableArray array];
        for (NSDictionary *item in SHArr(SHDict(json)[@"users"])) {
            SHUser *u = [SHUser fromJSON:item];
            if (u) [users addObject:u];
        }
        completion(users, nil);
    }];
}

#pragma mark - Follow / Unfollow

+ (SHHTTPTask *)followUser:(NSString *)pk completion:(SHActionCompletion)completion
{
    NSDictionary *params = @{ @"_uid": [SHSettings userId], @"_uuid": [SHSettings deviceId], @"user_id": pk };
    NSMutableDictionary *h = [SHAuthHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";
    return [SHHTTP request:@"POST"
        url:[NSString stringWithFormat:@"%@/friendships/create/%@/", SHApiBase, pk]
        headers:h body:SHSignedBodyData(params) retries:0
        completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *error) {
            id json = body.length ? [SHUtils JSONObjectFromData:body] : nil;
            BOOL ok = !error && status < 400;
            completion(ok, ok ? nil : (error ?: SHMakeError(status, [SHHTTP messageFromErrorJSON:json]
                                                             ?: [NSString stringWithFormat:L(@"Request failed (HTTP %ld)."), (long)status])));
        }];
}

// Following and asking to follow, with the relationship Instagram reports back (a private account turns a follow
// into a request); also the plain question of where the relationship stands.
static void SHReadFriendship(NSDictionary *fs, BOOL *following, BOOL *requested)
{
    *following = SHBool(fs[@"following"]);
    *requested = SHBool(fs[@"outgoing_request"]);
}

+ (SHHTTPTask *)friendshipWithUser:(NSString *)pk completion:(void (^)(BOOL following, BOOL requested, NSError *error))completion
{
    NSString *url = [NSString stringWithFormat:@"%@/friendships/show/%@/", SHApiBase, pk];
    return [SHHTTP getJSON:url headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(NO, NO, error); return; }
        BOOL following = NO, requested = NO;
        SHReadFriendship(SHDict(json), &following, &requested);
        completion(following, requested, nil);
    }];
}

+ (SHHTTPTask *)setFollowing:(BOOL)follow user:(NSString *)pk completion:(void (^)(BOOL following, BOOL requested, NSError *error))completion
{
    NSDictionary *params = @{ @"_uid": [SHSettings userId] ?: @"", @"_uuid": [SHSettings deviceId], @"user_id": pk ?: @"" };
    NSMutableDictionary *h = [SHAuthHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";
    NSString *url = [NSString stringWithFormat:@"%@/friendships/%@/%@/", SHApiBase, follow ? @"create" : @"destroy", pk];
    return [SHHTTP request:@"POST" url:url headers:h body:SHSignedBodyData(params) retries:0
                completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *error) {
        NSDictionary *d = SHDict(body.length ? [SHUtils JSONObjectFromData:body] : nil);
        if (error || status >= 400) {
            completion(NO, NO, error ?: SHMakeError(status, [SHHTTP messageFromErrorJSON:d]
                                                    ?: [NSString stringWithFormat:L(@"Request failed (HTTP %ld)."), (long)status]));
            return;
        }
        BOOL following = follow, requested = NO;
        NSDictionary *fs = SHDict(d[@"friendship_status"]);
        if (fs) SHReadFriendship(fs, &following, &requested);
        completion(following, requested, nil);
    }];
}

+ (SHHTTPTask *)unfollowUser:(NSString *)pk completion:(SHActionCompletion)completion
{
    NSDictionary *params = @{ @"_uid": [SHSettings userId], @"_uuid": [SHSettings deviceId], @"user_id": pk };
    NSMutableDictionary *h = [SHAuthHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";
    return [SHHTTP request:@"POST"
        url:[NSString stringWithFormat:@"%@/friendships/destroy/%@/", SHApiBase, pk]
        headers:h body:SHSignedBodyData(params) retries:0
        completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *error) {
            id json = body.length ? [SHUtils JSONObjectFromData:body] : nil;
            BOOL ok = !error && status < 400;
            completion(ok, ok ? nil : (error ?: SHMakeError(status, [SHHTTP messageFromErrorJSON:json]
                                                             ?: [NSString stringWithFormat:L(@"Request failed (HTTP %ld)."), (long)status])));
        }];
}

#pragma mark - Logout

+ (SHHTTPTask *)logoutWithCompletion:(SHActionCompletion)completion
{
    NSDictionary *params = @{ @"_uid": [SHSettings userId], @"_uuid": [SHSettings deviceId] };
    NSMutableDictionary *h = [SHAuthHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";
    return [SHHTTP request:@"POST"
        url:[SHApiBase stringByAppendingString:@"/accounts/logout/"]
        headers:h body:SHSignedBodyData(params) retries:0
        completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *error) {
            [self clearResponseCache];
            [SHSettings logout];
            completion(YES, nil);
        }];
}

#pragma mark - Challenge (checkpoint) flow

static NSString *g_challengePath = nil;
static NSString *g_challengeContext = nil;       // challenge.challenge_context of the reply that asked for the check
static NSDictionary *g_challengeStepData = nil;  // step_data of the current step (masked e-mail/phone, contact_point)

+ (void)setChallengePath:(NSString *)path
{
    g_challengePath = [path copy];
    g_challengeContext = nil;
    g_challengeStepData = nil;
}

+ (BOOL)hasPendingChallenge { return g_challengePath.length > 0; }
+ (NSDictionary *)challengeStepData { return g_challengeStepData; }

+ (void)registerChallengeObserver
{
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(challengeRequiredNotification:)
                                                 name:SHHTTPChallengeRequiredNotification object:nil];
}

// Every call of a stopped session brings the same challenge; only a new one replaces the pending one (and its step).
+ (void)challengeRequiredNotification:(NSNotification *)note
{
    NSDictionary *c = SHDict(SHDict(note.userInfo[@"json"])[@"challenge"]);
    NSString *path = SHStr(note.userInfo[@"path"]);
    if (!path.length) { SHLog(@"Instagram stopped the session for a security check, without a challenge path"); return; }
    if ([path isEqualToString:g_challengePath]) return;
    [self setChallengePath:path];
    g_challengeContext = [SHStr(c[@"challenge_context"]) copy];
    SHLog(@"Instagram stopped the session for a security check: %@ path, native_flow=%@ lock=%@ logout=%@ flow_render_type=%@ context=%@",
          [path componentsSeparatedByString:@"/"].count >= 5 ? @"user/nonce" : @"generic", c[@"native_flow"], c[@"lock"], c[@"logout"],
          c[@"flow_render_type"], g_challengeContext.length ? @"yes" : @"no");
}

// The challenge_context the app sends with the step request: the reply's own, else (like the app) one naming the
// user and the nonce of an api_path "/challenge/<user id>/<nonce>/".
static NSString *SHChallengeContextParameter(void)
{
    if (g_challengeContext.length) return g_challengeContext;
    NSArray *parts = [g_challengePath componentsSeparatedByString:@"/"];
    NSUInteger i = [parts indexOfObject:@"challenge"];
    if (i == NSNotFound || i + 2 >= parts.count) return nil;
    NSString *user = parts[i + 1], *nonce = parts[i + 2];
    if (!nonce.length || [user longLongValue] <= 0) return nil;
    NSData *json = [SHUtils JSONDataFromObject:@{ @"step_name": @"", @"nonce_code": nonce, @"user_id": @([user longLongValue]), @"is_stateless": @NO }];
    return json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
}

+ (NSString *)challengeURL
{
    NSString *p = g_challengePath;
    if (!p.length) return nil;
    if ([p hasPrefix:@"http"]) return p;
    if (![p hasPrefix:@"/"]) p = [@"/" stringByAppendingString:p];
    // api_path looks like "/challenge/12345/abcdef/"; it lives under the same /api/v1 base.
    return [SHApiBase stringByAppendingString:p];
}

+ (SHHTTPTask *)challengeFetchWithCompletion:(SHChallengeCompletion)completion
{
    NSString *url = [self challengeURL];
    if (!url) { completion(nil, NO, SHMakeError(SHErrorAPI, L(@"There is no pending verification."))); return nil; }
    // SHAuthHeaders carries the session when there is one (a checkpoint of a live session); before a login it is
    // just the device headers and the CSRF token. The device and the challenge identify themselves like the app's.
    NSMutableString *u = [url mutableCopy];
    [u appendFormat:@"%@guid=%@&device_id=%@", [url rangeOfString:@"?"].location == NSNotFound ? @"?" : @"&",
     [SHUtils urlEncode:[SHSettings deviceId]], [SHUtils urlEncode:[SHSettings androidId]]];
    NSString *context = SHChallengeContextParameter();
    if (context.length) [u appendFormat:@"&challenge_context=%@", [SHUtils urlEncode:context]];
    return [SHHTTP getJSON:u headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        if (error) { SHLog(@"Challenge step request failed: HTTP %ld %@", (long)status, error.localizedDescription); completion(nil, NO, error); return; }
        NSDictionary *d = SHDict(json);
        g_challengeStepData = SHDict(d[@"step_data"]);
        NSString *step = SHStr(d[@"step_name"]) ?: @"";
        if (!step.length && [SHStr(d[@"action"]) isEqualToString:@"close"]) step = @"close";
        completion(step, [step isEqualToString:@"select_verify_method"] || [step isEqualToString:@"select_contact_point_recovery"], nil);
    }];
}

+ (SHHTTPTask *)challengeSelectMethod:(NSInteger)choice completion:(SHChallengeCompletion)completion
{
    NSString *url = [self challengeURL];
    if (!url) { completion(nil, NO, SHMakeError(SHErrorAPI, L(@"There is no pending verification."))); return nil; }
    // "choice" answers whatever the step asks: the verification method (1 e-mail, 0 SMS), "it was me" (0) on a
    // login review, or the acknowledgement of an unusual-activity notice (0). Signed, like the app's own answers.
    NSDictionary *params = @{ @"choice": [NSString stringWithFormat:@"%ld", (long)choice], @"_csrftoken": [SHSettings csrfToken] ?: @"",
                              @"_uuid": [SHSettings deviceId], @"guid": [SHSettings deviceId], @"device_id": [SHSettings androidId] };
    NSMutableDictionary *h = [SHAuthHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";
    return [SHHTTP request:@"POST" url:url headers:h body:SHSignedBodyData(params) retries:0
                completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *error) {
        NSDictionary *d = SHDict(body.length ? [SHUtils JSONObjectFromData:body] : nil);
        if (error) { completion(nil, NO, error); return; }
        if (status >= 400) {
            SHLog(@"Challenge answer refused: HTTP %ld %@", (long)status, SHStr(d[@"message"]) ?: @"-");
            completion(nil, NO, SHMakeError(status, [SHHTTP messageFromErrorJSON:d] ?: L(@"That code didn't work. Try again.")));
            return;
        }
        g_challengeStepData = SHDict(d[@"step_data"]);
        NSString *step = SHStr(d[@"step_name"]) ?: @"";
        if (!step.length) step = [SHStr(d[@"action"]) isEqualToString:@"close"] || [SHStr(d[@"status"]) isEqualToString:@"ok"] ? @"close" : @"verify_code";
        if ([step isEqualToString:@"close"]) [self setChallengePath:nil];
        completion(step, [step isEqualToString:@"select_verify_method"] || [step isEqualToString:@"select_contact_point_recovery"], nil);
    }];
}

+ (SHHTTPTask *)challengeSubmitCode:(NSString *)code completion:(SHLoginCompletion)completion
{
    NSString *url = [self challengeURL];
    if (!url) { completion(nil, SHMakeError(SHErrorAPI, L(@"There is no pending verification."))); return nil; }
    NSMutableDictionary *h = [SHAuthHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";
    NSString *c = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    NSData *body = SHSignedBodyData(@{ @"security_code": c, @"_csrftoken": [SHSettings csrfToken] ?: @"", @"_uuid": [SHSettings deviceId],
                                       @"guid": [SHSettings deviceId], @"device_id": [SHSettings androidId] });
    return [SHHTTP request:@"POST" url:url headers:h body:body retries:0
                completion:^(NSInteger status, NSData *bodyData, NSDictionary *headers, NSError *error) {
        NSString *newCsrf = SHExtractCSRF(headers);
        if (newCsrf) [SHSettings setCsrfToken:newCsrf];
        SHSaveTokensFromHeaders(headers);
        NSDictionary *d = SHDict(bodyData.length ? [SHUtils JSONObjectFromData:bodyData] : nil);
        NSDictionary *loggedIn = SHDict(d[@"logged_in_user"]);
        if (loggedIn) {
            SHUser *user = [SHUser fromJSON:loggedIn];
            if (user.pk.length) { [SHSettings setUserId:user.pk]; [SHSettings setUsername:user.username]; [SHSettings save]; }
            [self setChallengePath:nil];
            completion(user, nil);
            return;
        }
        NSString *action = SHStr(d[@"action"]) ?: @"";
        if (([action isEqualToString:@"close"] || [SHStr(d[@"status"]) isEqualToString:@"ok"]) && [SHSettings isLoggedIn]) {
            [self setChallengePath:nil];
            completion(nil, nil);   // the token arrived in the headers; the feed will load the account
            return;
        }
        NSString *msg = SHStr(d[@"message"]) ?: (error.localizedDescription ?: L(@"That code didn't work. Try again."));
        completion(nil, SHMakeError(status ?: SHErrorAPI, msg));
    }];
}

#pragma mark - Connectivity probe (no password)

+ (SHHTTPTask *)probeConnectivityWithCompletion:(void (^)(BOOL ok, NSString *detail, NSError *error))completion
{
    return [self fetchEncryptionKeyWithCompletion:^(NSString *pubKey, NSInteger keyId, NSError *error) {
        if (error) { completion(NO, error.localizedDescription, error); return; }
        BOOL ok = pubKey.length > 0;
        NSString *detail = [NSString stringWithFormat:@"reached i.instagram.com: pubKey=%@ keyId=%ld csrf=%@",
            ok ? @"yes" : @"no", (long)keyId, [SHSettings csrfToken].length ? @"yes" : @"no"];
        completion(ok, detail, nil);
    }];
}

+ (SHHTTPTask *)encryptionSelfTestWithCompletion:(void (^)(BOOL ok, NSString *detail))completion
{
    return [self fetchEncryptionKeyWithCompletion:^(NSString *pubKey, NSInteger keyId, NSError *error) {
        if (error || !pubKey.length) { completion(NO, [NSString stringWithFormat:@"no pubkey (%@)", error.localizedDescription ?: @"?"]); return; }
        NSData *kd = [SHUtils base64Decode:pubKey];
        NSString *kind = (kd.length >= 10 && memcmp(kd.bytes, "-----BEGIN", 10) == 0) ? @"PEM" : @"DER/other";
        const char *sample = "selftest-not-a-credential";
        NSString *enc = SHEncryptPassword([NSString stringWithUTF8String:sample], pubKey, keyId);
        if (!enc.length) { completion(NO, [NSString stringWithFormat:@"SHEncryptPassword returned nil (pubkey=%@ %lu bytes)", kind, (unsigned long)kd.length]); return; }
        if (![enc hasPrefix:@"#PWD_INSTAGRAM:4:"]) {
            completion(NO, [NSString stringWithFormat:@"wrong prefix, plaintext fallback? %@", [enc substringToIndex:MIN((NSUInteger)20, enc.length)]]);
            return;
        }
        NSArray *parts = [enc componentsSeparatedByString:@":"];
        NSData *payload = parts.count >= 4 ? [SHUtils base64Decode:parts[3]] : nil;
        size_t expected = 2 + 12 + 2 + 256 + 16 + strlen(sample);
        if (payload.length < 32) { completion(NO, @"payload too short / base64 decode failed"); return; }
        const unsigned char *p = payload.bytes;
        int version = p[0];
        int kid = p[1];
        int rsaLen = p[14] | (p[15] << 8);
        BOOL ok = (version == 1 && kid == (int)keyId && rsaLen == 256 && payload.length == expected);
        completion(ok, [NSString stringWithFormat:@"pubkey=%@ v4=yes version=%d keyId=%d(exp %ld) rsaLen=%d payloadLen=%lu expected=%lu",
            kind, version, kid, (long)keyId, rsaLen, (unsigned long)payload.length, (unsigned long)expected]);
    }];
}

+ (SHHTTPTask *)loginFormatProbeWithCompletion:(void (^)(NSString *detail))completion
{
    return [self fetchEncryptionKeyWithCompletion:^(NSString *pubKey, NSInteger keyId, NSError *error) {
        if (error || !pubKey.length) { completion([NSString stringWithFormat:@"key fetch failed: %@", error.localizedDescription ?: @"?"]); return; }
        NSString *encPassword = SHEncryptPassword(@"selftest-not-a-credential", pubKey, keyId);
        if (!encPassword.length) { completion(@"enc_password nil (crypto failed)"); return; }
        // Probe the modern CAA endpoint with a non-existent username: shows whether the bloks login format is
        // accepted (no more needs_upgrade). A JSON error reply still parses; otherwise we snapshot the bloks body.
        [self caaSendLoginRequest:@"gramify_fmt_probe_000" encPassword:encPassword
            completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *err) {
                NSString *bodyStr = body.length ? ([[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"") : @"";
                NSDictionary *d = SHDict([SHUtils JSONObjectFromData:body]);
                BOOL needsUpgrade = [bodyStr rangeOfString:@"out of date" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [SHStr(d[@"error_type"]) isEqualToString:@"needs_upgrade"];
                NSString *bloks = SHExtractBloksError(bodyStr);
                NSString *snippet = bodyStr.length > 160 ? [bodyStr substringToIndex:160] : bodyStr;
                completion([NSString stringWithFormat:@"CAA HTTP %ld needs_upgrade=%@ error_type=%@ bloksErr=%@ body=%@",
                    (long)status, needsUpgrade ? @"YES" : @"no", SHStr(d[@"error_type"]) ?: @"-",
                    bloks ?: @"-", snippet]);
            }];
    }];
}

#pragma mark - Current user, lists and media info

+ (SHHTTPTask *)currentUserWithCompletion:(SHUserCompletion)completion
{
    NSString *url = [SHApiBase stringByAppendingString:@"/accounts/current_user/?edit=true"];
    return [SHHTTP getJSON:url headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, error); return; }
        SHUser *user = [SHUser fromJSON:SHDict(SHDict(json)[@"user"])];
        if (!user) { completion(nil, SHMakeError(SHErrorBadResponse, L(@"Couldn't load your profile."))); return; }
        if (user.pk.length) [SHSettings setUserId:user.pk];
        completion(user, nil);
    }];
}

+ (SHHTTPTask *)usersListAtPath:(NSString *)path maxId:(NSString *)maxId query:(NSString *)query
                     completion:(void (^)(NSArray *users, NSString *nextMaxId, NSError *error))completion
{
    NSMutableString *url = [NSMutableString stringWithString:path];
    [url appendString:[url rangeOfString:@"?"].location == NSNotFound ? @"?" : @"&"];
    if (maxId.length) [url appendFormat:@"max_id=%@&", [SHUtils urlEncode:maxId]];
    if (query.length) [url appendFormat:@"query=%@&", [SHUtils urlEncode:query]];
    return [SHHTTP getJSON:url headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, nil, error); return; }
        NSDictionary *d = SHDict(json);
        NSMutableArray *users = [NSMutableArray array];
        for (NSDictionary *item in SHArr(d[@"users"])) {
            SHUser *u = [SHUser fromJSON:item];
            if (u.pk.length) [users addObject:u];
        }
        completion(users, SHStr(d[@"next_max_id"]), nil);
    }];
}

+ (SHHTTPTask *)followersForPk:(NSString *)pk maxId:(NSString *)maxId query:(NSString *)query
                    completion:(void (^)(NSArray *users, NSString *nextMaxId, NSError *error))completion
{
    return [self usersListAtPath:[NSString stringWithFormat:@"%@/friendships/%@/followers/", SHApiBase, pk]
                           maxId:maxId query:query completion:completion];
}

+ (SHHTTPTask *)followingForPk:(NSString *)pk maxId:(NSString *)maxId query:(NSString *)query
                    completion:(void (^)(NSArray *users, NSString *nextMaxId, NSError *error))completion
{
    return [self usersListAtPath:[NSString stringWithFormat:@"%@/friendships/%@/following/", SHApiBase, pk]
                           maxId:maxId query:query completion:completion];
}

+ (SHHTTPTask *)likersForPost:(NSString *)mediaPk completion:(SHSearchCompletion)completion
{
    NSString *url = [NSString stringWithFormat:@"%@/media/%@/likers/", SHApiBase, mediaPk];
    return [SHHTTP getJSON:url headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSMutableArray *users = [NSMutableArray array];
        for (NSDictionary *item in SHArr(SHDict(json)[@"users"])) {
            SHUser *u = [SHUser fromJSON:item];
            if (u.pk.length) [users addObject:u];
        }
        completion(users, nil);
    }];
}

+ (SHHTTPTask *)mediaInfo:(NSString *)mediaPk completion:(SHMediaCompletion)completion
{
    NSString *url = [NSString stringWithFormat:@"%@/media/%@/info/", SHApiBase, mediaPk];
    return [SHHTTP getJSON:url headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, error); return; }
        SHPost *p = [SHPost fromJSON:SHDict([SHArr(SHDict(json)[@"items"]) firstObject])];
        if (!p.pk.length) { completion(nil, SHMakeError(SHErrorBadResponse, L(@"That post isn't available."))); return; }
        completion(p, nil);
    }];
}

#pragma mark - Explore and Activity

// Explore layouts change often, so pull every media-shaped node out of the response rather than relying on one shape.
static void SHCollectMedia(id node, NSMutableArray *out, NSMutableSet *seen)
{
    if ([node isKindOfClass:[NSArray class]]) {
        for (id child in node) SHCollectMedia(child, out, seen);
    } else if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = node;
        BOOL looksLikeMedia = d[@"media_type"] && (d[@"image_versions2"] || d[@"carousel_media"] || d[@"video_versions"]) && (d[@"pk"] || d[@"id"]);
        if (looksLikeMedia) {
            SHPost *p = [SHPost fromJSON:d];
            NSString *key = p.pk ?: @"";
            if (p.image.url.length && key.length && ![seen containsObject:key]) {
                [seen addObject:key];
                [out addObject:p];
            }
            return;   // don't descend into a media's own nested media (carousel children)
        }
        for (id key in d) SHCollectMedia(d[key], out, seen);
    }
}

+ (SHHTTPTask *)exploreWithMaxId:(NSString *)maxId completion:(SHFeedCompletion)completion
{
    NSMutableString *url = [NSMutableString stringWithFormat:@"%@/discover/topical_explore/?is_prefetch=false&module=explore_popular", SHApiBase];
    if (maxId.length) [url appendFormat:@"&max_id=%@", [SHUtils urlEncode:maxId]];
    return [SHHTTP getJSON:url headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, nil, error); return; }
        NSDictionary *d = SHDict(json);
        if (!maxId.length) SHResponseCacheStore(@"explore", d);
        completion(SHParseExplore(d), SHStr(d[@"next_max_id"]) ?: SHStr(d[@"rank_token"]), nil);
    }];
}

+ (SHHTTPTask *)newsInboxWithCompletion:(SHNewsCompletion)completion
{
    NSString *url = [SHApiBase stringByAppendingString:@"/news/inbox/?mark_as_seen=false"];
    return [SHHTTP getJSON:url headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSDictionary *d = SHDict(json);
        SHResponseCacheStore(@"news", d);
        completion(SHParseNews(d), nil);
    }];
}

// Reels come from the clips feeds the app's Reels tab uses (POST with the page in the query, as instagrapi does):
// clips/discover/ first, clips/connected/ when that one is empty, and the videos of the explore feed when both are
// (this account gets nothing from them at times). The page cursor carries which source it belongs to; the source
// that worked is remembered for the session, so the empty ones are not asked again and again.
static NSInteger g_reelsSource = 0;   // 0 discover, 1 connected, 2 explore videos

+ (SHHTTPTask *)reelsWithMaxId:(NSString *)maxId completion:(SHFeedCompletion)completion
{
    NSInteger source = g_reelsSource;
    NSString *cursor = maxId;
    if ([maxId hasPrefix:@"explore:"]) { source = 2; cursor = [maxId substringFromIndex:@"explore:".length]; }
    else if ([maxId hasPrefix:@"connected:"]) { source = 1; cursor = [maxId substringFromIndex:@"connected:".length]; }
    else if (maxId.length) source = 0;

    if (source >= 2) {
        return [self exploreWithMaxId:cursor.length ? cursor : nil completion:^(NSArray *posts, NSString *next, NSError *error) {
            NSMutableArray *videos = [NSMutableArray array];
            for (SHPost *p in posts) if (p.videoURL.length || p.mediaType == 2) [videos addObject:p];
            completion(videos, next.length ? [@"explore:" stringByAppendingString:next] : nil, error);
        }];
    }

    NSString *endpoint = source == 1 ? @"/clips/connected/" : @"/clips/discover/";
    NSMutableString *url = [NSMutableString stringWithFormat:@"%@%@", SHApiBase, endpoint];
    if (cursor.length) [url appendFormat:@"?max_id=%@", [SHUtils urlEncode:cursor]];
    NSDictionary *params = @{ @"_uuid": [SHSettings deviceId], @"_csrftoken": [SHSettings csrfToken] ?: @"",
                              @"container_module": @"clips_viewer_clips_tab", @"pagination_source": @"clips_viewer_clips_tab" };
    NSMutableDictionary *h = [SHAuthHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";
    __block SHHTTPTask *task = nil;
    task = [SHHTTP request:@"POST" url:url headers:h body:SHSignedBodyData(params) retries:0
                completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *error) {
        NSDictionary *d = SHDict(body.length ? [SHUtils JSONObjectFromData:body] : nil);
        NSArray *posts = (!error && status < 400) ? SHParseReels(d) : @[];
        if (!cursor.length && posts.count) SHResponseCacheStore(@"reels", d);   // the next opening starts with these
        if ([[NSFileManager defaultManager] fileExistsAtPath:[[SHUtils documentsPath] stringByAppendingPathComponent:@"debug"]])
            SHLog(@"REELS %@ status=%ld items=%lu with_ads=%lu firstKeys=%@ videos=%lu msg=%@", endpoint, (long)status,
                  (unsigned long)SHArr(d[@"items"]).count, (unsigned long)SHArr(d[@"items_with_ads"]).count,
                  [[SHDict([SHArr(d[@"items_with_ads"]) firstObject]) allKeys] componentsJoinedByString:@","],
                  (unsigned long)posts.count, SHStr(d[@"message"]) ?: @"-");
        if (posts.count) {
            NSDictionary *paging = SHDict(d[@"paging_info"]);
            NSString *next = SHStr(paging[@"max_id"]) ?: SHStr(d[@"next_max_id"]);
            BOOL more = paging[@"more_available"] ? SHBool(paging[@"more_available"]) : next.length > 0;
            if (more && next.length && source == 1) next = [@"connected:" stringByAppendingString:next];
            completion(posts, more ? next : nil, nil);
            return;
        }
        if (cursor.length) { completion(@[], nil, error); return; }   // a later page that ran dry: the end
        g_reelsSource = source + 1;                                   // this source is empty for us: the next one
        SHHTTPTask *inner = [self reelsWithMaxId:(source == 0 ? @"connected:" : @"explore:") completion:completion];
        task.cancelBlock = ^{ [inner cancel]; };
    }];
    return task;
}

#pragma mark - Saved posts

+ (SHHTTPTask *)savedFeedWithMaxId:(NSString *)maxId completion:(SHFeedCompletion)completion
{
    NSMutableString *url = [NSMutableString stringWithFormat:@"%@/feed/saved/posts/", SHApiBase];
    if (maxId.length) [url appendFormat:@"?max_id=%@", [SHUtils urlEncode:maxId]];
    return [SHHTTP getJSON:url headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, nil, error); return; }
        NSDictionary *d = SHDict(json);
        NSMutableArray *posts = [NSMutableArray array];
        for (NSDictionary *item in SHArr(d[@"items"])) {
            SHPost *p = [SHPost fromJSON:SHDict(item[@"media"]) ?: item];
            if (p.pk.length) [posts addObject:p];
        }
        completion(posts, SHStr(d[@"next_max_id"]), nil);
    }];
}

+ (SHHTTPTask *)setSaved:(BOOL)saved post:(NSString *)mediaPk completion:(SHActionCompletion)completion
{
    NSDictionary *params = @{ @"_uid": [SHSettings userId], @"_uuid": [SHSettings deviceId] };
    NSMutableDictionary *h = [SHAuthHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";
    NSString *url = [NSString stringWithFormat:@"%@/media/%@/%@/", SHApiBase, mediaPk, saved ? @"save" : @"unsave"];
    return [SHHTTP request:@"POST" url:url headers:h body:SHSignedBodyData(params) retries:0
                completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *error) {
        if (error) { completion(NO, error); return; }
        completion([SHStr(SHDict([SHUtils JSONObjectFromData:body])[@"status"]) isEqualToString:@"ok"], nil);
    }];
}

+ (SHHTTPTask *)savePost:(NSString *)mediaPk completion:(SHActionCompletion)completion { return [self setSaved:YES post:mediaPk completion:completion]; }
+ (SHHTTPTask *)unsavePost:(NSString *)mediaPk completion:(SHActionCompletion)completion { return [self setSaved:NO post:mediaPk completion:completion]; }

#pragma mark - Direct messages

+ (SHHTTPTask *)directInboxWithCursor:(NSString *)cursor completion:(SHThreadsCompletion)completion
{
    NSMutableString *url = [NSMutableString stringWithFormat:@"%@/direct_v2/inbox/?persistentBadging=true&limit=20&thread_message_limit=1", SHApiBase];
    if (cursor.length) [url appendFormat:@"&cursor=%@", [SHUtils urlEncode:cursor]];
    return [SHHTTP getJSON:url headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, nil, error); return; }
        NSString *next = nil;
        NSArray *threads = SHParseInbox(SHDict(json), &next);
        if (!cursor.length) SHResponseCacheStore(@"inbox", SHDict(json));
        completion(threads, next, nil);
    }];
}

+ (SHHTTPTask *)directThread:(NSString *)threadId cursor:(NSString *)cursor completion:(SHThreadCompletion)completion
{
    NSMutableString *url = [NSMutableString stringWithFormat:@"%@/direct_v2/threads/%@/?limit=20", SHApiBase, threadId];
    if (cursor.length) [url appendFormat:@"&cursor=%@", [SHUtils urlEncode:cursor]];
    return [SHHTTP getJSON:url headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, nil, error); return; }
        NSDictionary *t = SHDict(SHDict(json)[@"thread"]);
        SHDirectThread *thread = [SHDirectThread fromJSON:t];
        completion(thread, SHBool(t[@"has_older"]) ? SHStr(t[@"oldest_cursor"]) : nil, nil);
    }];
}

+ (SHHTTPTask *)sendDirectText:(NSString *)text toThread:(NSString *)threadId completion:(SHActionCompletion)completion
{
    NSMutableDictionary *h = [SHAuthHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";
    NSDictionary *fields = @{
        @"action": @"send_item",
        @"thread_ids": [NSString stringWithFormat:@"[%@]", threadId],
        @"client_context": [[NSUUID UUID] UUIDString],
        @"text": text,
        @"_uuid": [SHSettings deviceId],
        @"device_id": [SHSettings androidId],
    };
    NSString *url = [SHApiBase stringByAppendingString:@"/direct_v2/threads/broadcast/text/"];
    return [SHHTTP postForm:url headers:h fields:fields completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(NO, error); return; }
        completion([SHStr(SHDict(json)[@"status"]) isEqualToString:@"ok"], nil);
    }];
}

#pragma mark - Direct: posts, photos and voice

static BOOL SHDebugLogging(void)
{
    return [[NSFileManager defaultManager] fileExistsAtPath:[[SHUtils documentsPath] stringByAppendingPathComponent:@"debug"]];
}

// What the app sends as client_context / mutation_token: a 19-digit number.
static NSString *SHMutationToken(void)
{
    unsigned long long r = ((unsigned long long)arc4random() << 32) | arc4random();
    return [NSString stringWithFormat:@"6%018llu", r % 1000000000000000000ULL];
}

static NSString *SHJSONString(id object)
{
    NSData *d = [SHUtils JSONDataFromObject:object];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
}

// One item sent to a thread, or to a person (Instagram opens or finds the one-to-one thread): POST
// direct_v2/threads/broadcast/<item>/ with a plain form, as the app sends it. Answers the thread it went to.
static SHHTTPTask *SHDirectBroadcast(NSString *item, NSDictionary *fields, NSString *threadId, NSString *userPk,
                                     void (^completion)(BOOL ok, NSString *threadId, NSError *error))
{
    NSString *token = SHMutationToken();
    NSMutableDictionary *f = [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
    f[@"action"] = @"send_item";
    f[@"client_context"] = token;
    f[@"mutation_token"] = token;
    f[@"offline_threading_id"] = token;
    f[@"_uuid"] = [SHSettings deviceId];
    f[@"device_id"] = [SHSettings androidId];
    if ([SHSettings csrfToken].length) f[@"_csrftoken"] = [SHSettings csrfToken];
    if (threadId.length) f[@"thread_ids"] = [NSString stringWithFormat:@"[%@]", threadId];
    else f[@"recipient_users"] = [NSString stringWithFormat:@"[[%@]]", userPk ?: @""];
    NSMutableDictionary *h = [SHAuthHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";
    NSString *url = [NSString stringWithFormat:@"%@/direct_v2/threads/broadcast/%@/", SHApiBase, item];
    return [SHHTTP postForm:url headers:h fields:f completion:^(id json, NSInteger status, NSError *error) {
        NSDictionary *d = SHDict(json);
        BOOL ok = !error && [SHStr(d[@"status"]) isEqualToString:@"ok"];
        NSString *thread = SHStr(SHDict(d[@"payload"])[@"thread_id"]) ?: SHStr(SHDict([SHArr(d[@"message_metadata"]) firstObject])[@"thread_id"]) ?: threadId;
        if (SHDebugLogging())
            SHLog(@"DIRECT %@ status=%ld ok=%d thread=%@ %@", item, (long)status, ok, thread ?: @"-",
                  SHStr(d[@"message"]) ?: error.localizedDescription ?: @"");
        NSError *failure = nil;
        if (!ok) {
            // Instagram's own words when it has any; its HTTP 500 says just "None"
            NSString *text = [SHHTTP messageFromErrorJSON:json] ?: error.localizedDescription;
            if (!text.length || [[text lowercaseString] isEqualToString:@"none"]) {
                BOOL media = [item isEqualToString:@"configure_photo"] || [item isEqualToString:@"share_voice"]
                          || [item isEqualToString:@"voice_attachment"];
                text = media ? L(@"Instagram didn't accept it. In a message request they haven't accepted yet, only text can be sent.")
                             : L(@"The message didn't send.");
            }
            failure = SHMakeError(status >= 400 ? status : (error ? error.code : SHErrorAPI), text);
        }
        completion(ok, thread, failure);
    }];
}

static NSString *SHUploadIdNow(void)
{
    return [NSString stringWithFormat:@"%lld", (long long)([[NSDate date] timeIntervalSince1970] * 1000)];
}

static NSString *SHUploadName(NSString *uploadId)
{
    return [NSString stringWithFormat:@"%@_0_%u%09u", uploadId, 1 + arc4random_uniform(9), arc4random_uniform(1000000000)];
}

// rupload: the file itself, before it is sent (photo: rupload_igphoto, voice: rupload_igvideo). Answers the upload id.
static SHHTTPTask *SHRupload(NSString *kind, NSData *data, NSDictionary *params, NSString *uploadId, NSString *entityType,
                             void (^completion)(NSString *uploadId, NSError *error))
{
    NSString *name = SHUploadName(uploadId);
    NSMutableDictionary *h = [SHAuthHeaders() mutableCopy];
    h[@"X-Instagram-Rupload-Params"] = SHJSONString(params);
    h[[kind isEqualToString:@"igphoto"] ? @"X_FB_PHOTO_WATERFALL_ID" : @"X_FB_VIDEO_WATERFALL_ID"] = [[NSUUID UUID] UUIDString];
    h[@"X-Entity-Type"] = entityType;
    h[@"X-Entity-Name"] = name;
    h[@"X-Entity-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)data.length];
    h[@"Offset"] = @"0";
    h[@"Content-Type"] = @"application/octet-stream";
    NSString *url = [NSString stringWithFormat:@"https://i.instagram.com/rupload_%@/%@", kind, name];
    return [SHHTTP request:@"POST" url:url headers:h body:data retries:0
                completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *error) {
        NSDictionary *d = SHDict(body.length ? [SHUtils JSONObjectFromData:body] : nil);
        if (SHDebugLogging())
            SHLog(@"UPLOAD %@ %lu B status=%ld %@ %@", kind, (unsigned long)data.length, (long)status, SHStr(d[@"status"]) ?: @"-",
                  SHStr(d[@"message"]) ?: error.localizedDescription ?: @"");
        if (error || status >= 400 || ![SHStr(d[@"status"]) isEqualToString:@"ok"]) {
            NSString *text = [SHHTTP messageFromErrorJSON:d] ?: error.localizedDescription;
            if (!text.length || [[text lowercaseString] isEqualToString:@"none"]) text = L(@"The upload failed.");
            completion(nil, SHMakeError(status >= 400 ? status : (error ? error.code : SHErrorAPI), text));
            return;
        }
        completion(SHStr(d[@"upload_id"]) ?: uploadId, nil);
    }];
}

static NSString * const SHRetryContext = @"{\"num_step_auto_retry\":0,\"num_reupload\":0,\"num_step_manual_retry\":0}";

+ (SHHTTPTask *)sendDirectText:(NSString *)text toThread:(NSString *)threadId orUser:(NSString *)userPk
                    completion:(void (^)(BOOL ok, NSString *threadId, NSError *error))completion
{
    return SHDirectBroadcast(@"text", @{ @"text": text ?: @"" }, threadId, userPk, completion);
}

// The post as the app shares it into a chat (the paper plane under a post).
+ (SHHTTPTask *)sharePost:(SHPost *)post toThread:(NSString *)threadId orUser:(NSString *)userPk
               completion:(void (^)(BOOL ok, NSString *threadId, NSError *error))completion
{
    NSString *mediaId = [post.pk rangeOfString:@"_"].location != NSNotFound ? post.pk
                      : [NSString stringWithFormat:@"%@_%@", post.pk ?: @"", post.user.pk ?: @""];
    NSDictionary *fields = @{ @"media_id": mediaId, @"carousel_share_child_media_id": mediaId,
                              @"send_attribution": @"feed_timeline", @"unified_broadcast_format": @"1" };
    return SHDirectBroadcast(@"media_share", fields, threadId, userPk, completion);
}

// A photo into a chat: rupload_igphoto, then configure_photo.
+ (SHHTTPTask *)sendDirectPhoto:(NSData *)jpeg toThread:(NSString *)threadId completion:(SHActionCompletion)completion
{
    NSString *uploadId = SHUploadIdNow();
    NSDictionary *params = @{ @"retry_context": SHRetryContext, @"media_type": @"1", @"xsharing_user_ids": @"[]", @"upload_id": uploadId,
                              @"image_compression": @"{\"lib_name\":\"moz\",\"lib_version\":\"3.1.m\",\"quality\":\"80\"}" };
    __block SHHTTPTask *task = nil;
    task = SHRupload(@"igphoto", jpeg, params, uploadId, @"image/jpeg", ^(NSString *uploaded, NSError *error) {
        if (!uploaded) { completion(NO, error); return; }
        NSDictionary *fields = @{ @"upload_id": uploaded, @"allow_full_aspect_ratio": @"true", @"send_attribution": @"inbox" };
        SHHTTPTask *inner = SHDirectBroadcast(@"configure_photo", fields, threadId, nil, ^(BOOL ok, NSString *thread, NSError *err) {
            completion(ok, err);
        });
        task.cancelBlock = ^{ [inner cancel]; };
    });
    return task;
}

// The upload is finished before the voice message can be sent; Instagram may still be converting the audio and says
// so (a 202 or "transcode"): asked again a few times, a second apart.
static SHHTTPTask *SHUploadFinish(NSString *uploadId, NSInteger attempt, void (^completion)(BOOL ok, NSError *error))
{
    NSDictionary *device = @{ @"manufacturer": @"OnePlus", @"model": @"LE2123", @"android_version": @34, @"android_release": @"14" };
    NSDictionary *params = @{ @"timezone_offset": [NSString stringWithFormat:@"%ld", (long)[[NSTimeZone localTimeZone] secondsFromGMT]],
                              @"_csrftoken": [SHSettings csrfToken] ?: @"", @"source_type": @"4", @"_uid": [SHSettings userId] ?: @"",
                              @"device_id": [SHSettings androidId], @"_uuid": [SHSettings deviceId], @"upload_id": uploadId, @"device": device };
    NSMutableDictionary *h = [SHAuthHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";
    h[@"retry_context"] = SHRetryContext;
    __block SHHTTPTask *task = nil;
    task = [SHHTTP request:@"POST" url:[SHApiBase stringByAppendingString:@"/media/upload_finish/"] headers:h body:SHSignedBodyData(params)
                   retries:0 completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *error) {
        NSDictionary *d = SHDict(body.length ? [SHUtils JSONObjectFromData:body] : nil);
        NSString *message = SHStr(d[@"message"]) ?: @"";
        if (SHDebugLogging()) SHLog(@"UPLOAD finish %@ status=%ld %@ %@", uploadId, (long)status, SHStr(d[@"status"]) ?: @"-", message);
        BOOL pending = status == 202 || [[message lowercaseString] rangeOfString:@"transcode"].location != NSNotFound;
        if (pending && attempt < 5 && !error) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (task.isCancelled) return;
                SHHTTPTask *again = SHUploadFinish(uploadId, attempt + 1, completion);
                task.cancelBlock = ^{ [again cancel]; };
            });
            return;
        }
        BOOL ok = !error && status < 400 && [SHStr(d[@"status"]) isEqualToString:@"ok"];
        completion(ok, ok ? nil : (error ?: SHMakeError(status >= 400 ? status : SHErrorAPI, [SHHTTP messageFromErrorJSON:d] ?: L(@"The upload failed."))));
    }];
    return task;
}

// A voice message. broadcast/share_voice (after rupload_igvideo + upload_finish) answers 404 since 2025 ("no longer
// supported"); what the app does now, as reported in dilame/instagram-private-api#1832 (not confirmed there): the audio
// goes to rupload.facebook.com/messenger_audio/<upload id>, whose answer carries "media_id", and that is sent as an
// attachment with broadcast/voice_attachment, with the shape of the sound (levels 0-1, ten a second, comma-separated).
+ (SHHTTPTask *)sendDirectVoice:(NSData *)audio duration:(NSTimeInterval)duration waveform:(NSArray *)waveform
                       toThread:(NSString *)threadId completion:(SHActionCompletion)completion
{
    NSString *uploadId = SHUploadIdNow();
    NSDictionary *params = @{ @"message_id": uploadId, @"upload_id": uploadId, @"xsharing_user_ids": @"[]",
                              @"media_type": @11, @"is_direct_voice": @YES };
    NSMutableDictionary *h = [SHAuthHeaders() mutableCopy];
    h[@"X-Instagram-Rupload-Params"] = SHJSONString(params);
    h[@"X_FB_VIDEO_WATERFALL_ID"] = [[NSUUID UUID] UUIDString];
    // (AAC in an MP4 file, as recorded; announced the way the reported working request did: "audio/mp4" makes the
    // upload service answer ProcessingFailedError)
    h[@"X-Entity-Type"] = @"audio/aac";
    h[@"X-Entity-Name"] = [uploadId stringByAppendingString:@".m4a"];
    h[@"X-Entity-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)audio.length];
    h[@"Offset"] = @"0";
    h[@"X-Auth-Type"] = @"instagram";
    h[@"Content-Type"] = @"application/octet-stream";
    NSMutableArray *levels = [NSMutableArray array];
    for (NSNumber *n in waveform) [levels addObject:[NSString stringWithFormat:@"%.3f", n.doubleValue]];
    NSString *wave = levels.count ? [levels componentsJoinedByString:@","] : @"0.5";
    __block SHHTTPTask *task = nil;
    task = [SHHTTP request:@"POST" url:[@"https://rupload.facebook.com/messenger_audio/" stringByAppendingString:uploadId]
                   headers:h body:audio retries:0 completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *error) {
        NSDictionary *d = SHDict(body.length ? [SHUtils JSONObjectFromData:body] : nil);
        NSString *attachment = SHStr(d[@"media_id"]) ?: SHStr(d[@"fbid"]) ?: SHStr(d[@"attachment_fbid"]);
        if (SHDebugLogging()) {
            // (the upload service's answer is a short error object, no session in it: shown whole when it is small)
            NSString *raw = body.length && body.length < 600 ? [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] : nil;
            SHLog(@"UPLOAD messenger_audio %lu B %.1f s status=%ld keys=%@ attachment=%@ %@ body=%@", (unsigned long)audio.length, duration,
                  (long)status, [[d allKeys] componentsJoinedByString:@","], attachment.length ? @"yes" : @"no",
                  SHStr(d[@"message"]) ?: error.localizedDescription ?: @"", attachment.length ? @"-" : (raw ?: @"-"));
        }
        if (!attachment.length) {
            NSString *text = [SHHTTP messageFromErrorJSON:d] ?: error.localizedDescription;
            if (!text.length || [[text lowercaseString] isEqualToString:@"none"]) text = L(@"The upload failed.");
            completion(NO, SHMakeError(status >= 400 ? status : (error ? error.code : SHErrorAPI), text));
            return;
        }
        NSDictionary *fields = @{ @"upload_id": uploadId, @"attachment_fbid": attachment, @"waveform": wave,
                                  @"waveform_sampling_frequency_hz": @"10", @"send_attribution": @"direct_inbox",
                                  @"content_type": @"audio",
                                  @"client_timestamp": [NSString stringWithFormat:@"%lld", (long long)([[NSDate date] timeIntervalSince1970] * 1000)] };
        SHHTTPTask *send = SHDirectBroadcast(@"voice_attachment", fields, threadId, nil, ^(BOOL ok, NSString *thread, NSError *err) {
            completion(ok, err);
        });
        task.cancelBlock = ^{ [send cancel]; };
    }];
    return task;
}

#pragma mark - Hashtags

// The media of a tag page's sections: grids ("medias"), mixed rows ("fill_items") and the reels row.
static NSArray *SHParseTagSections(NSDictionary *d)
{
    NSMutableArray *posts = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    void (^add)(id) = ^(id node) {
        SHPost *p = [SHPost fromJSON:SHDict(SHDict(node)[@"media"])];
        if (p.pk.length && ![seen containsObject:p.pk] && (p.image.url.length || p.carouselMedia.count)) { [seen addObject:p.pk]; [posts addObject:p]; }
    };
    for (id section in SHArr(d[@"sections"])) {
        NSDictionary *content = SHDict(SHDict(section)[@"layout_content"]);
        for (id node in SHArr(content[@"medias"])) add(node);
        for (id node in SHArr(content[@"fill_items"])) add(node);
        for (id node in SHArr(SHDict(SHDict(content[@"one_by_two_item"])[@"clips"])[@"items"])) add(node);
    }
    for (id item in SHArr(d[@"items"])) add(@{ @"media": item });          // feed/tag/ answers a flat list
    for (id item in SHArr(d[@"ranked_items"])) add(@{ @"media": item });
    return posts;
}

+ (SHHTTPTask *)hashtagFeed:(NSString *)tag maxId:(NSString *)maxId completion:(SHFeedCompletion)completion
{
    NSString *t = [SHUtils urlEncode:tag ?: @""];
    NSMutableString *url = [NSMutableString stringWithFormat:@"%@/tags/%@/sections/", SHApiBase, t];
    if (maxId.length) [url appendFormat:@"?max_id=%@", [SHUtils urlEncode:maxId]];
    NSMutableDictionary *h = [SHAuthHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";
    NSDictionary *fields = @{ @"media_recency_filter": @"default", @"tab": @"top", @"_uuid": [SHSettings deviceId],
                              @"include_persistent": @"false", @"rank_token": [[[NSUUID UUID] UUIDString] lowercaseString] };
    __block SHHTTPTask *task = nil;
    task = [SHHTTP postForm:url headers:h fields:fields completion:^(id json, NSInteger status, NSError *error) {
        NSDictionary *d = SHDict(json);
        NSArray *posts = error ? @[] : SHParseTagSections(d);
        if (SHDebugLogging())
            SHLog(@"TAG #%@ status=%ld sections=%lu posts=%lu more=%@ %@", tag, (long)status, (unsigned long)SHArr(d[@"sections"]).count,
                  (unsigned long)posts.count, SHStr(d[@"more_available"]) ?: @"-", error.localizedDescription ?: @"");
        if (posts.count || maxId.length) {
            BOOL more = SHBool(d[@"more_available"]);
            completion(posts, more ? SHStr(d[@"next_max_id"]) : nil, posts.count ? nil : error);
            return;
        }
        // the older endpoint: a plain list of the tag's posts
        SHHTTPTask *inner = [SHHTTP getJSON:[NSString stringWithFormat:@"%@/feed/tag/%@/", SHApiBase, t] headers:SHAuthHeaders()
                                 completion:^(id json2, NSInteger status2, NSError *error2) {
            NSDictionary *d2 = SHDict(json2);
            NSArray *posts2 = error2 ? @[] : SHParseTagSections(d2);
            if (SHDebugLogging()) SHLog(@"TAG feed/tag #%@ status=%ld posts=%lu", tag, (long)status2, (unsigned long)posts2.count);
            if (!posts2.count && (error || error2)) { completion(nil, nil, error ?: error2); return; }
            completion(posts2, SHBool(d2[@"more_available"]) ? SHStr(d2[@"next_max_id"]) : nil, nil);
        }];
        task.cancelBlock = ^{ [inner cancel]; };
    }];
    return task;
}

+ (SHHTTPTask *)searchHashtags:(NSString *)query completion:(void (^)(NSArray *tags, NSError *error))completion
{
    NSString *q = [query hasPrefix:@"#"] ? [query substringFromIndex:1] : query;
    NSString *url = [NSString stringWithFormat:@"%@/tags/search/?q=%@&count=30&rank_token=%@", SHApiBase, [SHUtils urlEncode:q ?: @""],
                     [[[NSUUID UUID] UUIDString] lowercaseString]];
    return [SHHTTP getJSON:url headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSMutableArray *tags = [NSMutableArray array];
        for (id r in SHArr(SHDict(json)[@"results"])) {
            NSString *name = SHStr(SHDict(r)[@"name"]);
            if (name.length) [tags addObject:@{ @"name": name, @"count": @(SHInt(SHDict(r)[@"media_count"])) }];
        }
        completion(tags, nil);
    }];
}

@end
