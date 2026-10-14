#import <UIKit/UIKit.h>

// Simple alpha-mask glyphs for the bottom tab bar, drawn in code so they match on every device and are
// tinted by UIKit on iOS 6. Black-on-clear; the system turns them into the selected/unselected template.
@interface SHTabIcons : NSObject
+ (UIImage *)home;
+ (UIImage *)explore;     // a compass
+ (UIImage *)activity;    // a heart
+ (UIImage *)direct;      // a paper plane
+ (UIImage *)profile;     // a head and shoulders
@end
