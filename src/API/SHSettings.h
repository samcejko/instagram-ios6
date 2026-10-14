#import <Foundation/Foundation.h>

@interface SHSettings : NSObject

+ (void)registerDefaults;
+ (void)save;

+ (BOOL)isLoggedIn;
+ (NSString *)sessionToken;
+ (void)setSessionToken:(NSString *)token;
+ (NSString *)csrfToken;
+ (void)setCsrfToken:(NSString *)token;
+ (NSString *)wwwClaim;
+ (void)setWwwClaim:(NSString *)claim;
+ (NSString *)userId;
+ (void)setUserId:(NSString *)uid;
+ (NSString *)username;
+ (void)setUsername:(NSString *)name;
+ (NSString *)deviceId;
+ (NSString *)phoneId;
+ (NSString *)androidId;

+ (void)logout;

+ (BOOL)darkTheme;
+ (void)setDarkTheme:(BOOL)value;
+ (BOOL)verifyTLS;
+ (void)setVerifyTLS:(BOOL)value;

+ (NSArray *)searchHistory;
+ (void)addSearch:(NSString *)query;
+ (void)clearSearchHistory;

@end
