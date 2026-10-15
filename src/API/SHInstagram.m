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

                // Diagnostic (debug builds only): dump the server reply so a real login can be inspected without
                // ever logging the password or the session token's value.
                if ([[NSFileManager defaultManager] fileExistsAtPath:[[SHUtils documentsPath] stringByAppendingPathComponent:@"debug"]]) {
                    BOOL authPresent = NO;
                    for (NSString *k in headers) if ([[k lowercaseString] isEqualToString:@"ig-set-authorization"] && [headers[k] length] > 14) authPresent = YES;
                    NSString *dbg = body.length ? ([[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"") : @"";
                    SHLog(@"CAALOGIN HTTP %ld authHeader=%@ loggedIn=%@ bodyLen=%lu", (long)status, authPresent ? @"yes" : @"no", [SHSettings isLoggedIn] ? @"yes" : @"no", (unsigned long)dbg.length);
                    SHLog(@"CAALOGIN body: %@", dbg.length > 1400 ? [dbg substringToIndex:1400] : dbg);
                }

                if ([SHSettings isLoggedIn]) {
                    [SHSettings setUsername:username];
                    [SHSettings save];
                    completion(nil, nil, nil);      // signed in; the feed/profile load the account from the token
                    return;
                }

                NSString *bodyStr = body.length ? ([[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"") : @"";
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
    NSMutableString *url = [NSMutableString stringWithFormat:@"%@/feed/timeline/?is_pull_to_refresh=0", SHApiBase];
    if (maxId.length) [url appendFormat:@"&max_id=%@", [SHUtils urlEncode:maxId]];

    return [SHHTTP getJSON:url headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, nil, error); return; }
        NSDictionary *d = SHDict(json);
        NSMutableArray *posts = [NSMutableArray array];
        for (NSDictionary *item in SHArr(d[@"feed_items"]) ?: SHArr(d[@"items"])) {
            NSDictionary *mediaNode = SHDict(item[@"media_or_ad"]) ?: item;
            SHPost *p = [SHPost fromJSON:mediaNode];
            if (p && p.pk.length) [posts addObject:p];
        }
        completion(posts, SHStr(d[@"next_max_id"]), nil);
    }];
}

#pragma mark - Users

+ (SHHTTPTask *)userInfoByUsername:(NSString *)username completion:(SHUserCompletion)completion
{
    NSString *url = [NSString stringWithFormat:@"%@/users/web_profile_info/?username=%@",
                     SHApiBase, [SHUtils urlEncode:username]];
    return [SHHTTP getJSON:url headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSDictionary *d = SHDict(json);
        NSDictionary *userData = SHDict(d[@"data"][@"user"]) ?: SHDict(d[@"user"]);
        SHUser *user = [SHUser fromJSON:userData];
        if (!user) { completion(nil, SHMakeError(SHErrorBadResponse, L(@"User not found."))); return; }
        completion(user, nil);
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
        for (NSDictionary *tray in SHArr(d[@"tray"])) {
            SHStoryReel *r = [SHStoryReel fromJSON:tray];
            if (r && r.user) [reels addObject:r];
        }
        completion(reels, nil);
    }];
}

+ (SHHTTPTask *)storiesForUserIds:(NSArray *)userIds completion:(SHStoriesCompletion)completion
{
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    NSMutableArray *ids = [NSMutableArray array];
    for (id uid in userIds) [ids addObject:SHStr(uid) ?: @""];
    params[@"user_ids"] = ids;

    NSMutableDictionary *h = [SHAuthHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";

    return [SHHTTP postForm:[NSString stringWithFormat:@"%@/feed/reels_media/", SHApiBase]
                    headers:h fields:@{ @"user_ids": [[ids componentsJoinedByString:@","] stringByReplacingOccurrencesOfString:@" " withString:@""] }
                 completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, error); return; }
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
        completion(reels, nil);
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
            completion(!error, error);
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
            completion(!error, error);
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
            [SHSettings logout];
            completion(YES, nil);
        }];
}

#pragma mark - Challenge (checkpoint) flow

static NSString *g_challengePath = nil;

+ (void)setChallengePath:(NSString *)path { g_challengePath = [path copy]; }
+ (BOOL)hasPendingChallenge { return g_challengePath.length > 0; }

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
    NSMutableDictionary *h = [SHCommonHeaders() mutableCopy];
    NSString *csrf = [SHSettings csrfToken];
    if (csrf.length) h[@"X-CSRFToken"] = csrf;
    return [SHHTTP getJSON:url headers:h completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, NO, error); return; }
        NSString *step = SHStr(SHDict(json)[@"step_name"]) ?: @"";
        completion(step, [step isEqualToString:@"select_verify_method"], nil);
    }];
}

+ (SHHTTPTask *)challengeSelectMethod:(NSInteger)choice completion:(SHChallengeCompletion)completion
{
    NSString *url = [self challengeURL];
    if (!url) { completion(nil, NO, SHMakeError(SHErrorAPI, L(@"There is no pending verification."))); return nil; }
    NSMutableDictionary *h = [SHCommonHeaders() mutableCopy];
    NSString *csrf = [SHSettings csrfToken];
    if (csrf.length) h[@"X-CSRFToken"] = csrf;
    return [SHHTTP postForm:url headers:h fields:@{ @"choice": [NSString stringWithFormat:@"%ld", (long)choice] }
                 completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, NO, error); return; }
        NSString *step = SHStr(SHDict(json)[@"step_name"]) ?: @"verify_code";
        completion(step, NO, nil);
    }];
}

+ (SHHTTPTask *)challengeSubmitCode:(NSString *)code completion:(SHLoginCompletion)completion
{
    NSString *url = [self challengeURL];
    if (!url) { completion(nil, SHMakeError(SHErrorAPI, L(@"There is no pending verification."))); return nil; }
    NSMutableDictionary *h = [SHCommonHeaders() mutableCopy];
    h[@"Content-Type"] = @"application/x-www-form-urlencoded";
    NSString *csrf = [SHSettings csrfToken];
    if (csrf.length) h[@"X-CSRFToken"] = csrf;
    NSString *c = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    NSData *body = [[NSString stringWithFormat:@"security_code=%@", [SHUtils urlEncode:c]] dataUsingEncoding:NSUTF8StringEncoding];
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
        NSMutableArray *posts = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        SHCollectMedia(d[@"sectional_items"] ?: d[@"items"] ?: d, posts, seen);
        completion(posts, SHStr(d[@"next_max_id"]) ?: SHStr(d[@"rank_token"]) , nil);
    }];
}

+ (SHHTTPTask *)newsInboxWithCompletion:(SHNewsCompletion)completion
{
    NSString *url = [SHApiBase stringByAppendingString:@"/news/inbox/"];
    return [SHHTTP getJSON:url headers:SHAuthHeaders() completion:^(id json, NSInteger status, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSDictionary *d = SHDict(json);
        NSMutableArray *stories = [NSMutableArray array];
        for (NSDictionary *s in SHArr(d[@"new_stories"])) { SHNewsStory *n = [SHNewsStory fromJSON:s]; if (n) [stories addObject:n]; }
        for (NSDictionary *s in SHArr(d[@"old_stories"])) { SHNewsStory *n = [SHNewsStory fromJSON:s]; if (n) [stories addObject:n]; }
        completion(stories, nil);
    }];
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
        NSDictionary *inbox = SHDict(SHDict(json)[@"inbox"]);
        NSMutableArray *threads = [NSMutableArray array];
        for (NSDictionary *t in SHArr(inbox[@"threads"])) {
            SHDirectThread *thread = [SHDirectThread fromJSON:t];
            if (thread.threadId.length) [threads addObject:thread];
        }
        NSString *next = SHBool(inbox[@"has_older"]) ? SHStr(inbox[@"oldest_cursor"]) : nil;
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

@end
