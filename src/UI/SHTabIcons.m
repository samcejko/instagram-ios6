#import "SHTabIcons.h"

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
        CGContextStrokeEllipseInRect(ctx, CGRectMake(4, 4, s - 8, s - 8));
        CGFloat c = s / 2;
        // the compass needle (two triangles)
        CGContextMoveToPoint(ctx, c, c);
        CGContextAddLineToPoint(ctx, s * 0.66, s * 0.34);
        CGContextAddLineToPoint(ctx, c, c);
        CGContextAddLineToPoint(ctx, s * 0.34, s * 0.66);
        CGContextClosePath(ctx);
        CGContextFillPath(ctx);
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

@end
