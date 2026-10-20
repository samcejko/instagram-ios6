#import "SHCommon.h"

#include <stdio.h>
#include <string.h>
#include <time.h>

NSString * const SHErrorDomain                   = @"com.samcejko.Shutter";
NSString * const SHThemeDidChangeNotification     = @"SHThemeDidChangeNotification";
NSString * const SHSettingsDidChangeNotification  = @"SHSettingsDidChangeNotification";
NSString * const SHLibraryDidChangeNotification   = @"SHLibraryDidChangeNotification";

NSError *SHMakeError(NSInteger code, NSString *message)
{
    if (!message) message = @"Unknown error";
    return [NSError errorWithDomain:SHErrorDomain code:code userInfo:@{ NSLocalizedDescriptionKey: message }];
}

NSString *SHStr(id value)
{
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return nil;
}

NSDictionary *SHDict(id value)
{
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

NSArray *SHArr(id value)
{
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

NSInteger SHInt(id value)
{
    if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) return [value integerValue];
    return 0;
}

double SHDbl(id value)
{
    if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) return [value doubleValue];
    return 0;
}

BOOL SHBool(id value)
{
    if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) return [value boolValue];
    return NO;
}

NSDate *SHDateFromISO(NSString *string)
{
    if (![string isKindOfClass:[NSString class]] || string.length < 19) return nil;
    // (NSDateFormatter is slow and not thread safe; the format is fixed, so the fields are read directly)
    int y = 0, mo = 0, d = 0, h = 0, mi = 0;
    double s = 0;
    if (sscanf([string UTF8String], "%d-%d-%dT%d:%d:%lf", &y, &mo, &d, &h, &mi, &s) != 6) return nil;
    struct tm t;
    memset(&t, 0, sizeof(t));
    t.tm_year = y - 1900;
    t.tm_mon = mo - 1;
    t.tm_mday = d;
    t.tm_hour = h;
    t.tm_min = mi;
    t.tm_sec = (int)s;
    time_t seconds = timegm(&t);
    if (seconds == (time_t)-1) return nil;
    return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)seconds + (s - (int)s)];
}


// CFUUID is available before iOS 6 and preserves the UUID string format.
NSString *SHUniqueIdentifier(void)
{
    CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
    CFStringRef value = CFUUIDCreateString(kCFAllocatorDefault, uuid);
    CFRelease(uuid);
    return (__bridge_transfer NSString *)value;
}
