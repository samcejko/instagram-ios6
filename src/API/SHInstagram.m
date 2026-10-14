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
static NSString * const SHAppVersion   = @"269.0.0.18.75";
static NSString * const SHVersionCode  = @"314665256";
static NSString * const SHSignatureKey = @"SIGNATURE";

#pragma mark - User-Agent and headers

static NSString *SHUserAgent(void)
{
    return [NSString stringWithFormat:
        @"Instagram %@ Android (26/8.0.0; 640dpi; 1440x2560; samsung; SM-G965F; star2qltecs; samsungexynos9810; en_US; %@)",
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

    NSData *pubKeyDer = [SHUtils base64Decode:pubKeyBase64];
    if (!pubKeyDer) return nil;

    mbedtls_pk_context pk;
    mbedtls_pk_init(&pk);
    int ret = mbedtls_pk_parse_public_key(&pk, pubKeyDer.bytes, pubKeyDer.length);
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
    // Instagram decrypts this with RSA-OAEP using SHA-1 for both the hash and MGF1 (the default of
    // PKCS1_OAEP in pycryptodome and of RSA_PKCS1_OAEP_PADDING in Node, which every working client uses).
    // Using SHA-256 here makes the server's decrypt fail and the login is reported as a wrong password.
    mbedtls_rsa_set_padding(rsa, MBEDTLS_RSA_PKCS_V21, MBEDTLS_MD_SHA1);
    size_t rsaLen = mbedtls_rsa_get_len(rsa);
    unsigned char *rsaOut = malloc(rsaLen);
    ret = mbedtls_rsa_rsaes_oaep_encrypt(rsa, mbedtls_ctr_drbg_random, &ctr_drbg,
                                          NULL, 0, 32, aesKey, rsaOut);
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
                [SHSettings setSessionToken:[val substringFromIndex:@"Bearer IGT:2:".length]];
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

#pragma mark - Login

@implementation SHInstagram

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

        NSDictionary *params = @{
            @"jazoest": SHJazoest([SHSettings phoneId]),
            @"country_codes": @"[{\"country_code\":\"1\",\"source\":[\"default\"]}]",
            @"phone_id": [SHSettings phoneId],
            @"enc_password": encPassword,
            @"username": username,
            @"adid": [[NSUUID UUID] UUIDString],
            @"guid": [SHSettings deviceId],
            @"device_id": [SHSettings androidId],
            @"google_tokens": @"[]",
            @"login_attempt_count": @"0",
        };
        NSMutableDictionary *h = [SHCommonHeaders() mutableCopy];
        h[@"Content-Type"] = @"application/x-www-form-urlencoded";
        NSString *csrf = [SHSettings csrfToken];
        if (csrf.length) h[@"X-CSRFToken"] = csrf;

        SHHTTPTask *inner = [SHHTTP request:@"POST"
            url:[SHApiBase stringByAppendingString:@"/accounts/login/"]
            headers:h body:SHSignedBodyData(params) retries:0
            completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *loginErr) {
                NSString *newCsrf = SHExtractCSRF(headers);
                if (newCsrf) [SHSettings setCsrfToken:newCsrf];
                SHSaveTokensFromHeaders(headers);

                id json = body.length ? [SHUtils JSONObjectFromData:body] : nil;
                NSDictionary *d = SHDict(json);

                if (SHBool(d[@"two_factor_required"])) {
                    NSDictionary *info = SHDict(d[@"two_factor_info"]);
                    NSString *tfId = SHStr(info[@"two_factor_identifier"]) ?: @"";
                    completion(nil, tfId, nil);
                    return;
                }
                NSString *message = SHStr(d[@"message"]);
                if ([message isEqualToString:@"challenge_required"]) {
                    // A fresh device almost always triggers this: Instagram wants an e-mail/SMS code before the
                    // account may sign in. Remember where to continue and let the UI run the challenge flow.
                    NSDictionary *challenge = SHDict(d[@"challenge"]);
                    NSString *path = SHStr(challenge[@"api_path"]);
                    if (!path.length) {
                        NSString *url = SHStr(challenge[@"url"]);
                        NSRange r = [url rangeOfString:@"/challenge/"];
                        if (r.location != NSNotFound) path = [url substringFromIndex:r.location];
                    }
                    [self setChallengePath:path];
                    NSError *err = SHMakeError(SHErrorChallenge,
                        L(@"Instagram needs to verify it's you. A code will be sent to your e-mail or phone."));
                    completion(nil, nil, err);
                    return;
                }
                if (loginErr || !SHBool(d[@"authenticated"])) {
                    NSString *msg = message;
                    if ([message isEqualToString:@"checkpoint_required"])
                        msg = L(@"Instagram asked for a security check. Open the Instagram app or instagram.com once, approve this login, then try again.");
                    else if (SHStr(d[@"error_type"]) && [SHStr(d[@"error_type"]) isEqualToString:@"bad_password"])
                        msg = L(@"The password you entered is incorrect.");
                    else if (SHStr(d[@"error_type"]) && [SHStr(d[@"error_type"]) isEqualToString:@"invalid_user"])
                        msg = L(@"That username doesn't belong to an account.");
                    if (!msg.length) msg = loginErr.localizedDescription ?: L(@"Login failed.");
                    completion(nil, nil, SHMakeError(status ?: SHErrorAPI, msg));
                    return;
                }
                SHUser *user = [SHUser fromJSON:SHDict(d[@"logged_in_user"])];
                if (user) {
                    [SHSettings setUserId:user.pk];
                    [SHSettings setUsername:user.username];
                    [SHSettings save];
                }
                completion(user, nil, nil);
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
