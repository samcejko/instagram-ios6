#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface SHUtils : NSObject

// Formatting
+ (NSString *)formatCount:(NSInteger)count;                 // 843, 12.3K, 1.2M
+ (NSString *)formatBigCount:(long long)count;              // the same, up to 5.8B (TikTok's view counts)
+ (NSString *)formatViewers:(NSInteger)count;               // "12.3K viewers"
+ (NSString *)formatDuration:(NSTimeInterval)seconds;       // 1:02:03, 4:05
+ (NSString *)formatUptimeSince:(NSDate *)date;             // 2:47 (hours:minutes), "3 min"
+ (NSString *)formatRelativeDate:(NSDate *)date;            // "2 hours ago", "3 days ago", else a short date
+ (NSString *)formatFileSize:(unsigned long long)bytes;
+ (NSString *)truncate:(NSString *)string to:(NSUInteger)length;
// The text without the emoji this system has no picture for (they came after 2012 and would show as empty boxes).
// `dropped` (may be nil) receives the range of every character left out, in the original string's UTF-16 units.
+ (NSString *)displayText:(NSString *)text;
+ (NSString *)displayText:(NSString *)text dropped:(NSMutableArray *)dropped;
// The web links in a text (what the system's data detector finds: "https://…", "www.…", "example.com/…"), as
// NSTextCheckingResult: the range in `text` and the URL (http:// added where the text had no scheme). Mail addresses
// are left out, and so is the domain-like tail of a @mention or a #hashtag ("@john.name").
+ (NSArray *)webLinksInText:(NSString *)text;
// A link as a button title: without the scheme and "www.", cut to `length` characters (NSURL or NSString)
+ (NSString *)linkTitle:(id)link length:(NSUInteger)length;

// Encoding
+ (NSString *)urlEncode:(NSString *)string;                 // RFC 3986 unreserved characters stay
+ (NSString *)sha1:(NSString *)string;
+ (NSString *)base64Encode:(NSData *)data;
+ (NSData *)base64Decode:(NSString *)string;
+ (id)JSONObjectFromData:(NSData *)data;
+ (NSData *)JSONDataFromObject:(id)object;
+ (NSDictionary *)parseQuery:(NSString *)query;             // "a=1&b=2" (percent decoding applied)

// Device
+ (NSString *)deviceModel;                                  // "iPad2,2"
+ (BOOL)deviceIsOldGeneration;                              // A4 and older: video up to 720p30, less memory
+ (NSUInteger)physicalMemoryMB;
+ (CGFloat)screenScale;

// App
+ (NSString *)appVersion;                                   // "0.1.0 (1)"
+ (NSString *)cachesPath;
+ (NSString *)documentsPath;
+ (void)alertWithTitle:(NSString *)title message:(NSString *)message;

// Colors
+ (UIColor *)colorFromHex:(NSString *)hex;                  // "#RRGGBB", nil when it does not parse
// A chat name colour made readable on the given background (too dark on dark / too light on light is shifted)
+ (UIColor *)readableColor:(UIColor *)color onDark:(BOOL)dark;

// Images
+ (UIImage *)imageWithColor:(UIColor *)color size:(CGSize)size;

@end
