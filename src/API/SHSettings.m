#import "SHSettings.h"
#import "SHKeychain.h"
#import "SHCommon.h"

#define DEF [NSUserDefaults standardUserDefaults]

static NSString * const SHSessionTokenKey = @"shutter.sessionToken";
static NSString * const SHCsrfTokenKey    = @"shutter.csrfToken";

@implementation SHSettings

+ (void)registerDefaults
{
    [DEF registerDefaults:@{
        @"darkTheme": @YES,
        @"verifyTLS": @YES,
        @"searchHistory": @[],
        @"userId": @"",
        @"username": @"",
        @"messageSounds": @YES,
        @"dataSaver": @NO,
    }];
    if (![DEF stringForKey:@"deviceId"].length)
        [DEF setObject:SHUniqueIdentifier() forKey:@"deviceId"];
    if (![DEF stringForKey:@"phoneId"].length)
        [DEF setObject:SHUniqueIdentifier() forKey:@"phoneId"];
    if (![DEF stringForKey:@"androidId"].length) {
        uint64_t r = 0;
        arc4random_buf(&r, sizeof(r));
        [DEF setObject:[NSString stringWithFormat:@"android-%016llx", r] forKey:@"androidId"];
    }
    [DEF synchronize];
}

+ (void)save { [DEF synchronize]; }

+ (void)notify
{
    SHMain(^{ [[NSNotificationCenter defaultCenter] postNotificationName:SHSettingsDidChangeNotification object:nil]; });
}

#pragma mark - Session

+ (BOOL)isLoggedIn { return [self sessionToken].length > 0; }

+ (NSString *)sessionToken { return [SHKeychain stringForKey:SHSessionTokenKey] ?: @""; }
+ (void)setSessionToken:(NSString *)token { [SHKeychain setString:token forKey:SHSessionTokenKey]; }

+ (NSString *)csrfToken { return [SHKeychain stringForKey:SHCsrfTokenKey] ?: @""; }
+ (void)setCsrfToken:(NSString *)token { [SHKeychain setString:token forKey:SHCsrfTokenKey]; }

+ (NSString *)wwwClaim { return [DEF stringForKey:@"wwwClaim"] ?: @""; }
+ (void)setWwwClaim:(NSString *)claim { [DEF setObject:claim ?: @"" forKey:@"wwwClaim"]; }

+ (NSString *)userId { return [DEF stringForKey:@"userId"] ?: @""; }
+ (void)setUserId:(NSString *)uid { [DEF setObject:uid ?: @"" forKey:@"userId"]; [self save]; }

+ (NSString *)username { return [DEF stringForKey:@"username"] ?: @""; }
+ (void)setUsername:(NSString *)name { [DEF setObject:name ?: @"" forKey:@"username"]; [self save]; }

+ (NSString *)deviceId { return [DEF stringForKey:@"deviceId"]; }
+ (NSString *)phoneId { return [DEF stringForKey:@"phoneId"]; }
+ (NSString *)androidId { return [DEF stringForKey:@"androidId"]; }

+ (NSString *)machineId { return [DEF stringForKey:@"machineId"] ?: @""; }
+ (void)setMachineId:(NSString *)mid { if (mid.length) [DEF setObject:mid forKey:@"machineId"]; }

+ (void)renewDeviceIds
{
    [DEF removeObjectForKey:@"deviceId"];
    [DEF removeObjectForKey:@"phoneId"];
    [DEF removeObjectForKey:@"androidId"];
    [DEF removeObjectForKey:@"machineId"];
    [self registerDefaults];
}

+ (void)logout
{
    [self setSessionToken:@""];
    [self setCsrfToken:@""];
    [self setWwwClaim:@""];
    [self setUserId:@""];
    [self setUsername:@""];
    [self notify];
}

#pragma mark - Appearance / network

+ (BOOL)dataSaver { return [DEF boolForKey:@"dataSaver"]; }
+ (void)setDataSaver:(BOOL)value { [DEF setBool:value forKey:@"dataSaver"]; [self save]; [self notify]; }
+ (NSString *)threadThemeKey:(NSString *)threadId
{
    return [NSString stringWithFormat:@"chatTheme.%@.%@", [self userId], threadId];
}
+ (NSInteger)themeForThread:(NSString *)threadId
{
    if (!threadId.length || ![self userId].length) return 0;
    NSInteger value = [DEF integerForKey:[self threadThemeKey:threadId]];
    return value >= 0 && value <= 3 ? value : 0;
}
+ (void)setTheme:(NSInteger)theme forThread:(NSString *)threadId
{
    if (!threadId.length || ![self userId].length || theme < 0 || theme > 3) return;
    NSString *key = [self threadThemeKey:threadId];
    if (theme) [DEF setInteger:theme forKey:key]; else [DEF removeObjectForKey:key];
    [self save];
}
+ (BOOL)darkTheme { return [DEF boolForKey:@"darkTheme"]; }
+ (void)setDarkTheme:(BOOL)value { [DEF setBool:value forKey:@"darkTheme"]; [self notify]; }
+ (BOOL)messageSounds { return [DEF boolForKey:@"messageSounds"]; }
+ (void)setMessageSounds:(BOOL)value { [DEF setBool:value forKey:@"messageSounds"]; [self notify]; }
+ (BOOL)verifyTLS { return [DEF boolForKey:@"verifyTLS"]; }
+ (void)setVerifyTLS:(BOOL)value { [DEF setBool:value forKey:@"verifyTLS"]; [self notify]; }

#pragma mark - Search

+ (NSArray *)searchHistory
{
    NSMutableArray *out = [NSMutableArray array];
    for (id q in SHArr([DEF objectForKey:@"searchHistory"])) if (SHStr(q).length) [out addObject:SHStr(q)];
    return out;
}

+ (void)addSearch:(NSString *)query
{
    NSString *q = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!q.length) return;
    NSMutableArray *list = [[self searchHistory] mutableCopy];
    for (NSInteger i = (NSInteger)list.count - 1; i >= 0; i--)
        if ([list[(NSUInteger)i] caseInsensitiveCompare:q] == NSOrderedSame) [list removeObjectAtIndex:(NSUInteger)i];
    [list insertObject:q atIndex:0];
    while (list.count > 20) [list removeLastObject];
    [DEF setObject:list forKey:@"searchHistory"];
}

+ (void)clearSearchHistory { [DEF setObject:@[] forKey:@"searchHistory"]; }

@end
