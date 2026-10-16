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
+ (NSString *)machineId;                 // Instagram's "mid" for this device (ig-set-x-mid), "" before it sent one
+ (void)setMachineId:(NSString *)mid;
+ (void)renewDeviceIds;                  // (debug, while logged out) a new device in Instagram's eyes

+ (void)logout;

+ (BOOL)darkTheme;
+ (void)setDarkTheme:(BOOL)value;
+ (BOOL)messageSounds;                   // the sounds of a message coming in and going out (default on)
+ (void)setMessageSounds:(BOOL)value;
+ (BOOL)verifyTLS;
+ (void)setVerifyTLS:(BOOL)value;

+ (NSArray *)searchHistory;
+ (void)addSearch:(NSString *)query;
+ (void)clearSearchHistory;

@end
