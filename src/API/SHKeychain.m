#import "SHLegacyCollections.h"
#import "SHKeychain.h"
#import "SHCommon.h"
#import <Security/Security.h>

static NSString * const SHKeychainService = @"com.samcejko.shutter";

@implementation SHKeychain

+ (NSMutableDictionary *)queryForKey:(NSString *)key
{
    return [@{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
               (__bridge id)kSecAttrService: SHKeychainService,
               (__bridge id)kSecAttrAccount: key ?: @"" } mutableCopy];
}

// Where a value lives when the keychain did not take it, and the mark that says so.
+ (NSString *)fallbackKey:(NSString *)key { return [@"kc." stringByAppendingString:key ?: @""]; }
+ (NSString *)fallbackMarkKey:(NSString *)key { return [@"kc-in-prefs." stringByAppendingString:key ?: @""]; }

+ (NSString *)keychainStringForKey:(NSString *)key
{
    NSMutableDictionary *q = [self queryForKey:key];
    SHLegacyDictionarySet(q, (__bridge id)kSecReturnData, (__bridge id)kCFBooleanTrue);
    SHLegacyDictionarySet(q, (__bridge id)kSecMatchLimit, (__bridge id)kSecMatchLimitOne);
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &result) == errSecSuccess && result) {
        NSData *data = (__bridge_transfer NSData *)result;
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    return nil;
}

+ (NSString *)stringForKey:(NSString *)key
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // A value the keychain refused is in the preferences, and the keychain may still hold an older one (another
    // install of the app left it there and it could not be removed): the newer one wins.
    if ([defaults boolForKey:[self fallbackMarkKey:key]]) return [defaults stringForKey:[self fallbackKey:key]];
    return [self keychainStringForKey:key] ?: [defaults stringForKey:[self fallbackKey:key]];
}

+ (void)setString:(NSString *)value forKey:(NSString *)key
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *q = [self queryForKey:key];
    SecItemDelete((__bridge CFDictionaryRef)q);
    [defaults removeObjectForKey:[self fallbackKey:key]];
    [defaults removeObjectForKey:[self fallbackMarkKey:key]];

    OSStatus status = errSecSuccess;
    if (value.length) {
        NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
        SHLegacyDictionarySet(q, (__bridge id)kSecValueData, data);
        SHLegacyDictionarySet(q, (__bridge id)kSecAttrAccessible, (__bridge id)kSecAttrAccessibleAfterFirstUnlock);
        status = SecItemAdd((__bridge CFDictionaryRef)q, NULL);
        if (status == errSecDuplicateItem) {   // an item that could not be deleted: written over instead
            status = SecItemUpdate((__bridge CFDictionaryRef)[self queryForKey:key],
                                   (__bridge CFDictionaryRef)@{ (__bridge id)kSecValueData: data });
        }
    }
    // Only what the keychain gives back is left to it; anything else goes to the preferences, marked as the one
    // that counts (an old session token read back from the keychain made every request "session expired"). That
    // holds for an empty value too: a logout the keychain did not take must not bring the old token back.
    NSString *readBack = [self keychainStringForKey:key];
    if (value.length ? (status == errSecSuccess && [readBack isEqualToString:value]) : !readBack.length) {
        [defaults synchronize];
        return;
    }
    if (value.length) [defaults setObject:value forKey:[self fallbackKey:key]];
    [defaults setBool:YES forKey:[self fallbackMarkKey:key]];
    [defaults synchronize];
    SHLog(@"Keychain: %@ kept in the preferences (status %d)", key, (int)status);
}

@end
