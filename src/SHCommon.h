// Shared macros and constants. Everything here must be iOS 6.0 safe.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Any API newer than the iOS 6.0 deployment target is a hard error in files that include this header.
#pragma clang diagnostic error "-Wunguarded-availability"

#define L(key) NSLocalizedString((key), nil)
#define SHIsPad() (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
#define SHLog(fmt, ...) NSLog((@"[Shutter] " fmt), ##__VA_ARGS__)

// Runs a block on the main thread (immediately if already there).
static inline void SHMain(dispatch_block_t block)
{
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

extern NSString * const SHErrorDomain;
extern NSString * const SHThemeDidChangeNotification;
extern NSString * const SHSettingsDidChangeNotification;
extern NSString * const SHLibraryDidChangeNotification;     // saved posts or following changed

// NSError codes in SHErrorDomain (HTTP errors use the HTTP status as code)
enum {
    SHErrorNetwork        = -1,
    SHErrorTLS            = -2,
    SHErrorCertificate    = -3,
    SHErrorTimeout        = -4,
    SHErrorCancelled      = -5,
    SHErrorBadResponse    = -6,
    SHErrorDNS            = -7,
    SHErrorConnect        = -8,
    SHErrorConnectionLost = -9,
    SHErrorAPI            = -10,   // Instagram answered, but with an error
    SHErrorOffline        = -11,
    SHErrorAuth           = -12,   // authentication required or session expired
    SHErrorRestricted     = -13,   // private account, blocked content
    SHErrorChallenge      = -14,   // Instagram wants an e-mail/SMS verification code before the login completes
};

NSError *SHMakeError(NSInteger code, NSString *message);

// JSON values as the type the caller expects, nil/0 for anything else (NSNull, wrong type)
NSString *SHStr(id value);         // numbers become their decimal string
NSDictionary *SHDict(id value);
NSArray *SHArr(id value);
NSInteger SHInt(id value);
double SHDbl(id value);
BOOL SHBool(id value);

// "2026-10-02T17:31:00Z" and "2026-10-02T17:31:05.042684Z"
NSDate *SHDateFromISO(NSString *string);
