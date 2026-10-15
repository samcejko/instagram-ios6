#import "SHTabIcons.h"
#include <math.h>

@implementation SHTabIcons

static UIImage *SHIconDraw(void (^draw)(CGContextRef ctx, CGFloat s))
{
    CGFloat s = 30;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(s, s), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor blackColor] setFill];
    [[UIColor blackColor] setStroke];
    CGContextSetLineWidth(ctx, 2);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    draw(ctx, s);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    // On iOS 6 the tab bar treats an icon's alpha as a mask and tints it itself, so the raw image is what we want.
    return img;
}

+ (UIImage *)home
{
    return SHIconDraw(^(CGContextRef ctx, CGFloat s) {
        // a house: roof triangle + body
        CGContextMoveToPoint(ctx, 4, s * 0.5);
        CGContextAddLineToPoint(ctx, s * 0.5, 4);
        CGContextAddLineToPoint(ctx, s - 4, s * 0.5);
        CGContextStrokePath(ctx);
        CGRect body = CGRectMake(7, s * 0.5, s - 14, s * 0.42);
        CGContextStrokeRect(ctx, body);
        // a door
        CGRect door = CGRectMake(s * 0.5 - 2.5, s * 0.72, 5, s * 0.2);
        CGContextFillRect(ctx, door);
    });
}

+ (UIImage *)explore
{
    return SHIconDraw(^(CGContextRef ctx, CGFloat s) {
        // a magnifying glass: a thick lens and a handle
        CGContextSetLineWidth(ctx, 3.5);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(4, 4, s * 0.52, s * 0.52));
        CGContextSetLineWidth(ctx, 4.5);
        CGContextMoveToPoint(ctx, s * 0.6, s * 0.6);
        CGContextAddLineToPoint(ctx, s - 3.5, s - 3.5);
        CGContextStrokePath(ctx);
    });
}

+ (UIImage *)activity
{
    return SHIconDraw(^(CGContextRef ctx, CGFloat s) {
        CGFloat w = s, h = s;
        CGContextMoveToPoint(ctx, w * 0.5, h * 0.82);
        CGContextAddCurveToPoint(ctx, w * 0.1, h * 0.5, w * 0.12, h * 0.16, w * 0.3, h * 0.18);
        CGContextAddCurveToPoint(ctx, w * 0.44, h * 0.19, w * 0.5, h * 0.32, w * 0.5, h * 0.36);
        CGContextAddCurveToPoint(ctx, w * 0.5, h * 0.32, w * 0.56, h * 0.19, w * 0.7, h * 0.18);
        CGContextAddCurveToPoint(ctx, w * 0.88, h * 0.16, w * 0.9, h * 0.5, w * 0.5, h * 0.82);
        CGContextClosePath(ctx);
        CGContextFillPath(ctx);
    });
}

+ (UIImage *)direct
{
    return SHIconDraw(^(CGContextRef ctx, CGFloat s) {
        // a paper plane
        CGContextMoveToPoint(ctx, s - 4, 4);
        CGContextAddLineToPoint(ctx, 4, s * 0.45);
        CGContextAddLineToPoint(ctx, s * 0.44, s * 0.52);
        CGContextAddLineToPoint(ctx, s * 0.62, s - 4);
        CGContextClosePath(ctx);
        CGContextFillPath(ctx);
    });
}

+ (UIImage *)profile
{
    return SHIconDraw(^(CGContextRef ctx, CGFloat s) {
        CGContextFillEllipseInRect(ctx, CGRectMake(s * 0.3, 4, s * 0.4, s * 0.4));   // head
        CGContextMoveToPoint(ctx, s * 0.12, s - 3);
        CGContextAddCurveToPoint(ctx, s * 0.14, s * 0.55, s * 0.86, s * 0.55, s * 0.88, s - 3);   // shoulders
        CGContextClosePath(ctx);
        CGContextFillPath(ctx);
    });
}

#pragma mark - Post action glyphs

// Draws the shape twice: first one point off in the shadow colour, then in its own colour on top (the emboss).
static UIImage *SHGlyphDraw(CGFloat size, UIColor *color, BOOL dark, void (^addPath)(CGContextRef ctx, CGFloat s), BOOL fill)
{
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size + 1), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetLineWidth(ctx, MAX(1.5, size / 13));
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    UIColor *shadow = dark ? [UIColor colorWithWhite:0 alpha:0.7] : [UIColor colorWithWhite:1 alpha:0.8];
    CGFloat shapeY = dark ? 1 : 0, shadowY = dark ? 0 : 1;   // dark surface: the shadow sits above the shape
    for (int pass = 0; pass < 2; pass++) {
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, 0, pass == 0 ? shadowY : shapeY);
        UIColor *c = pass == 0 ? shadow : color;
        [c setFill];
        [c setStroke];
        addPath(ctx, size);
        if (fill) CGContextFillPath(ctx); else CGContextStrokePath(ctx);
        CGContextRestoreGState(ctx);
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

+ (UIImage *)heartWithSize:(CGFloat)size filled:(BOOL)filled color:(UIColor *)color dark:(BOOL)dark
{
    return SHGlyphDraw(size, color, dark, ^(CGContextRef ctx, CGFloat s) {
        CGFloat w = s, h = s;
        CGContextMoveToPoint(ctx, w * 0.5, h * 0.86);
        CGContextAddCurveToPoint(ctx, w * 0.08, h * 0.52, w * 0.1, h * 0.16, w * 0.3, h * 0.17);
        CGContextAddCurveToPoint(ctx, w * 0.43, h * 0.18, w * 0.5, h * 0.3, w * 0.5, h * 0.35);
        CGContextAddCurveToPoint(ctx, w * 0.5, h * 0.3, w * 0.57, h * 0.18, w * 0.7, h * 0.17);
        CGContextAddCurveToPoint(ctx, w * 0.9, h * 0.16, w * 0.92, h * 0.52, w * 0.5, h * 0.86);
        CGContextClosePath(ctx);
    }, filled);
}

+ (UIImage *)commentBubbleWithSize:(CGFloat)size color:(UIColor *)color dark:(BOOL)dark
{
    return SHGlyphDraw(size, color, dark, ^(CGContextRef ctx, CGFloat s) {
        // a rounded speech balloon with its tail at the lower left
        CGFloat r = s * 0.22, x0 = s * 0.1, y0 = s * 0.16, x1 = s * 0.9, y1 = s * 0.72;
        CGContextMoveToPoint(ctx, x0 + r, y0);
        CGContextAddArcToPoint(ctx, x1, y0, x1, y0 + r, r);
        CGContextAddArcToPoint(ctx, x1, y1, x1 - r, y1, r);
        CGContextAddLineToPoint(ctx, s * 0.46, y1);
        CGContextAddLineToPoint(ctx, s * 0.24, s * 0.9);    // the tail
        CGContextAddLineToPoint(ctx, s * 0.27, y1);
        CGContextAddArcToPoint(ctx, x0, y1, x0, y1 - r, r);
        CGContextAddArcToPoint(ctx, x0, y0, x0 + r, y0, r);
        CGContextClosePath(ctx);
    }, NO);
}

+ (UIImage *)bookmarkWithSize:(CGFloat)size filled:(BOOL)filled color:(UIColor *)color dark:(BOOL)dark
{
    return SHGlyphDraw(size, color, dark, ^(CGContextRef ctx, CGFloat s) {
        CGContextMoveToPoint(ctx, s * 0.26, s * 0.12);
        CGContextAddLineToPoint(ctx, s * 0.74, s * 0.12);
        CGContextAddLineToPoint(ctx, s * 0.74, s * 0.9);
        CGContextAddLineToPoint(ctx, s * 0.5, s * 0.7);
        CGContextAddLineToPoint(ctx, s * 0.26, s * 0.9);
        CGContextClosePath(ctx);
    }, filled);
}

+ (UIImage *)paperPlaneWithSize:(CGFloat)size color:(UIColor *)color dark:(BOOL)dark
{
    return SHGlyphDraw(size, color, dark, ^(CGContextRef ctx, CGFloat s) {
        // the outline of a paper plane flying up to the right, with its fold
        CGContextMoveToPoint(ctx, s * 0.1, s * 0.46);
        CGContextAddLineToPoint(ctx, s * 0.9, s * 0.12);
        CGContextAddLineToPoint(ctx, s * 0.62, s * 0.88);
        CGContextAddLineToPoint(ctx, s * 0.47, s * 0.58);
        CGContextClosePath(ctx);
        CGContextMoveToPoint(ctx, s * 0.47, s * 0.58);
        CGContextAddLineToPoint(ctx, s * 0.9, s * 0.12);
    }, NO);
}

+ (UIImage *)cameraWithSize:(CGFloat)size color:(UIColor *)color dark:(BOOL)dark
{
    return SHGlyphDraw(size, color, dark, ^(CGContextRef ctx, CGFloat s) {
        // the body with the viewfinder bump, the lens in the middle
        CGFloat r = s * 0.1, x0 = s * 0.08, x1 = s * 0.92, y0 = s * 0.3, y1 = s * 0.84;
        CGContextMoveToPoint(ctx, x0 + r, y0);
        CGContextAddLineToPoint(ctx, s * 0.33, y0);
        CGContextAddLineToPoint(ctx, s * 0.39, s * 0.19);
        CGContextAddLineToPoint(ctx, s * 0.61, s * 0.19);
        CGContextAddLineToPoint(ctx, s * 0.67, y0);
        CGContextAddArcToPoint(ctx, x1, y0, x1, y0 + r, r);
        CGContextAddArcToPoint(ctx, x1, y1, x1 - r, y1, r);
        CGContextAddArcToPoint(ctx, x0, y1, x0, y1 - r, r);
        CGContextAddArcToPoint(ctx, x0, y0, x0 + r, y0, r);
        CGContextClosePath(ctx);
        CGContextAddEllipseInRect(ctx, CGRectMake(s * 0.33, s * 0.41, s * 0.34, s * 0.34));
    }, NO);
}

+ (UIImage *)photosWithSize:(CGFloat)size color:(UIColor *)color dark:(BOOL)dark
{
    return SHGlyphDraw(size, color, dark, ^(CGContextRef ctx, CGFloat s) {
        // a framed picture: hills and the sun
        CGContextAddRect(ctx, CGRectMake(s * 0.1, s * 0.2, s * 0.8, s * 0.62));
        CGContextMoveToPoint(ctx, s * 0.14, s * 0.74);
        CGContextAddLineToPoint(ctx, s * 0.38, s * 0.48);
        CGContextAddLineToPoint(ctx, s * 0.55, s * 0.64);
        CGContextAddLineToPoint(ctx, s * 0.66, s * 0.54);
        CGContextAddLineToPoint(ctx, s * 0.86, s * 0.74);
        CGContextAddEllipseInRect(ctx, CGRectMake(s * 0.62, s * 0.29, s * 0.12, s * 0.12));
    }, NO);
}

+ (UIImage *)microphoneWithSize:(CGFloat)size color:(UIColor *)color dark:(BOOL)dark
{
    return SHGlyphDraw(size, color, dark, ^(CGContextRef ctx, CGFloat s) {
        // the capsule, the holder round its lower half, the stand
        CGFloat w = s * 0.26, x = s * 0.5 - w / 2, top = s * 0.1, bottom = s * 0.58;
        CGContextMoveToPoint(ctx, x, top + w / 2);
        CGContextAddArc(ctx, s * 0.5, top + w / 2, w / 2, (CGFloat)M_PI, 0, 0);
        CGContextAddLineToPoint(ctx, x + w, bottom - w / 2);
        CGContextAddArc(ctx, s * 0.5, bottom - w / 2, w / 2, 0, (CGFloat)M_PI, 0);
        CGContextClosePath(ctx);
        CGContextMoveToPoint(ctx, s * 0.24, s * 0.46);
        CGContextAddArc(ctx, s * 0.5, s * 0.46, s * 0.26, (CGFloat)M_PI, 0, 1);
        CGContextMoveToPoint(ctx, s * 0.5, s * 0.72);
        CGContextAddLineToPoint(ctx, s * 0.5, s * 0.88);
        CGContextMoveToPoint(ctx, s * 0.34, s * 0.88);
        CGContextAddLineToPoint(ctx, s * 0.66, s * 0.88);
    }, NO);
}

+ (UIImage *)personWithSize:(CGFloat)size color:(UIColor *)color dark:(BOOL)dark
{
    return SHGlyphDraw(size, color, dark, ^(CGContextRef ctx, CGFloat s) {
        CGContextAddEllipseInRect(ctx, CGRectMake(s * 0.32, s * 0.1, s * 0.36, s * 0.36));
        CGContextMoveToPoint(ctx, s * 0.14, s * 0.9);
        CGContextAddCurveToPoint(ctx, s * 0.16, s * 0.52, s * 0.84, s * 0.52, s * 0.86, s * 0.9);
        CGContextClosePath(ctx);
    }, YES);
}

@end
