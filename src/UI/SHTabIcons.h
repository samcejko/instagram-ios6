#import <UIKit/UIKit.h>

// Simple alpha-mask glyphs for the bottom tab bar, drawn in code so they match on every device and are
// tinted by UIKit on iOS 6. Black-on-clear; the system turns them into the selected/unselected template.
@interface SHTabIcons : NSObject
+ (UIImage *)home;
+ (UIImage *)explore;     // a compass
+ (UIImage *)activity;    // a heart
+ (UIImage *)direct;      // a paper plane
+ (UIImage *)profile;     // a head and shoulders

// Action glyphs under a post (like, comment, save), drawn in a colour with the iOS 6 emboss: a hairline of
// shadow beside the shape (light below it on a light surface, dark above it on a dark one), so the glyph looks
// pressed into the surface rather than printed on it.
+ (UIImage *)heartWithSize:(CGFloat)size filled:(BOOL)filled color:(UIColor *)color dark:(BOOL)dark;
+ (UIImage *)commentBubbleWithSize:(CGFloat)size color:(UIColor *)color dark:(BOOL)dark;
+ (UIImage *)bookmarkWithSize:(CGFloat)size filled:(BOOL)filled color:(UIColor *)color dark:(BOOL)dark;
+ (UIImage *)paperPlaneWithSize:(CGFloat)size color:(UIColor *)color dark:(BOOL)dark;   // share
+ (UIImage *)cameraWithSize:(CGFloat)size color:(UIColor *)color dark:(BOOL)dark;
+ (UIImage *)photosWithSize:(CGFloat)size color:(UIColor *)color dark:(BOOL)dark;       // the photo library
+ (UIImage *)microphoneWithSize:(CGFloat)size color:(UIColor *)color dark:(BOOL)dark;
+ (UIImage *)personWithSize:(CGFloat)size color:(UIColor *)color dark:(BOOL)dark;       // people tagged on a photo
@end
