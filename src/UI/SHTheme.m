#import "SHLegacyCollections.h"
#import "SHTheme.h"
#import "SHSettings.h"
#import "SHUtils.h"
#import "SHModern.h"
#import "SHCommon.h"

static UIImage *SHStretchImage(UIImage *image, UIEdgeInsets caps)
{
    if ([image respondsToSelector:@selector(resizableImageWithCapInsets:resizingMode:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
        return [image resizableImageWithCapInsets:caps resizingMode:UIImageResizingModeStretch];
#pragma clang diagnostic pop
    }
    return [image stretchableImageWithLeftCapWidth:(NSInteger)caps.left topCapHeight:(NSInteger)caps.top];
}

static UIColor *RGB(NSInteger r, NSInteger g, NSInteger b)
{
    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1.0];
}

static void SHDrawVerticalGradient(CGContextRef ctx, CGRect rect, UIColor *top, UIColor *bottom)
{
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    NSArray *colors = @[ (id)top.CGColor, (id)bottom.CGColor ];
    CGFloat locations[2] = { 0.0, 1.0 };
    CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, locations);
    CGContextDrawLinearGradient(ctx, gradient, CGPointMake(rect.origin.x, CGRectGetMinY(rect)), CGPointMake(rect.origin.x, CGRectGetMaxY(rect)), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
}

// A rounded, vertically shaded rectangle with an optional glossy top half, as a stretchable image.
static UIImage *SHRoundedGradientImage(UIColor *top, UIColor *bottom, UIColor *stroke, CGFloat radius, BOOL gloss)
{
    CGFloat side = radius * 2 + 12;
    CGRect rect = CGRectMake(0, 0, side, side);
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect inner = CGRectInset(rect, 0.5, 0.5);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:inner cornerRadius:radius];
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path.CGPath);
    CGContextClip(ctx);
    SHDrawVerticalGradient(ctx, rect, top, bottom);
    if (gloss) {
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.22].CGColor);
        CGContextFillRect(ctx, CGRectMake(0, 0, side, floor(side / 2)));
    }
    CGContextRestoreGState(ctx);
    if (stroke) {
        [stroke setStroke];
        path.lineWidth = 1.0;
        [path stroke];
    }
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    CGFloat cap = radius + 5;
    return SHStretchImage(image, UIEdgeInsetsMake(cap, cap, cap, cap));
}

// A bar background: top highlight hairline, gradient body, bottom line.
static UIImage *SHBarImage(UIColor *top, UIColor *bottom, UIColor *line, CGFloat height)
{
    CGSize size = CGSizeMake(4, height);
    UIGraphicsBeginImageContextWithOptions(size, YES, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    SHDrawVerticalGradient(ctx, CGRectMake(0, 0, size.width, height), top, bottom);
    [[UIColor colorWithWhite:1.0 alpha:0.35] setFill];
    UIRectFill(CGRectMake(0, 0, size.width, 1));
    [line setFill];
    UIRectFill(CGRectMake(0, height - 1, size.width, 1));
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return SHStretchImage(image, UIEdgeInsetsMake(2, 1, 2, 1));
}

// Draws with a block into an image of the given size (transparent background)
static UIImage *SHDrawImage(CGSize size, void (^draw)(CGContextRef ctx))
{
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    draw(UIGraphicsGetCurrentContext());
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

@interface SHTheme ()
@property (nonatomic) BOOL dark;
@property (nonatomic, strong) NSMutableDictionary *imageCache;
@end

@implementation SHTheme

+ (instancetype)shared
{
    static SHTheme *theme;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ theme = [[SHTheme alloc] init]; });
    return theme;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _dark = [SHSettings darkTheme];
        _imageCache = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)isDark { return self.dark; }

- (void)setDark:(BOOL)dark
{
    _dark = dark;
    [SHSettings setDarkTheme:dark];
    [SHSettings save];
    [self.imageCache removeAllObjects];
    [[UIApplication sharedApplication] setStatusBarStyle:[self statusBarStyle] animated:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:SHThemeDidChangeNotification object:self];
}

- (void)invalidateArtwork
{
    [self.imageCache removeAllObjects];
    [[NSNotificationCenter defaultCenter] postNotificationName:SHThemeDidChangeNotification object:self];
}

#pragma mark - Colors

- (UIColor *)backgroundColor { return self.dark ? RGB(18, 18, 20) : RGB(229, 231, 236); }
- (UIColor *)cardColor { return self.dark ? RGB(32, 32, 36) : [UIColor whiteColor]; }
- (UIColor *)primaryTextColor { return self.dark ? RGB(240, 240, 242) : RGB(24, 24, 28); }
- (UIColor *)textColor { return [self primaryTextColor]; }
- (UIColor *)secondaryTextColor { return self.dark ? RGB(150, 150, 158) : RGB(112, 112, 120); }
- (UIColor *)separatorColor { return self.dark ? RGB(55, 55, 60) : RGB(200, 200, 206); }
- (UIColor *)accentColor { return self.dark ? RGB(0, 149, 246) : RGB(0, 120, 210); }   // Instagram blue
- (UIColor *)liveColor { return RGB(224, 32, 32); }
- (UIColor *)linkColor { return self.dark ? RGB(120, 175, 245) : RGB(30, 90, 200); }
- (UIColor *)chatBackgroundColor { return self.dark ? RGB(24, 24, 27) : RGB(250, 250, 252); }
- (UIColor *)chatTextColor { return self.dark ? RGB(235, 235, 238) : RGB(28, 28, 32); }
- (UIColor *)chatSystemTextColor { return self.dark ? RGB(150, 150, 158) : RGB(110, 110, 118); }
- (UIColor *)chatMentionColor { return self.dark ? RGB(70, 50, 30) : RGB(255, 240, 200); }
- (UIColor *)chatHighlightColor { return self.dark ? RGB(45, 35, 70) : RGB(236, 228, 250); }
- (UIColor *)chatDeletedTextColor { return self.dark ? RGB(120, 120, 128) : RGB(150, 150, 158); }
- (UIColor *)chatSeparatorColor { return self.dark ? RGB(40, 40, 44) : RGB(232, 232, 236); }
- (UIColor *)inputTextColor { return self.dark ? RGB(240, 240, 242) : RGB(20, 20, 22); }
- (UIColor *)placeholderColor { return self.dark ? RGB(120, 120, 128) : RGB(160, 160, 168); }
- (UIColor *)playerBackgroundColor { return [UIColor blackColor]; }

#pragma mark - Artwork

- (UIImage *)cachedImage:(NSString *)key builder:(UIImage *(^)(void))builder
{
    UIImage *image = [self.imageCache objectForKey:key];
    if (!image) {
        image = builder();
        if (image) SHLegacyDictionarySet(self.imageCache, key, image);
    }
    return image;
}

- (UIImage *)cardBackgroundImage
{
    return [self cachedImage:@"card" builder:^UIImage *{
        if (self.dark) return SHRoundedGradientImage(RGB(44, 44, 49), RGB(32, 32, 36), RGB(60, 60, 66), 6, NO);
        return SHRoundedGradientImage(RGB(255, 255, 255), RGB(246, 246, 249), RGB(188, 190, 198), 6, NO);
    }];
}

- (UIImage *)cardBackgroundImageHighlighted
{
    return [self cachedImage:@"card-hi" builder:^UIImage *{
        if (self.dark) return SHRoundedGradientImage(RGB(60, 60, 66), RGB(48, 48, 54), RGB(75, 75, 82), 6, NO);
        return SHRoundedGradientImage(RGB(222, 226, 236), RGB(208, 213, 226), RGB(170, 175, 190), 6, NO);
    }];
}

- (UIImage *)pillImageWithColor:(UIColor *)color
{
    CGFloat r = 0, g = 0, b = 0, a = 1;
    [color getRed:&r green:&g blue:&b alpha:&a];
    NSString *key = [NSString stringWithFormat:@"pill-%.2f-%.2f-%.2f", r, g, b];
    return [self cachedImage:key builder:^UIImage *{
        UIColor *top = [UIColor colorWithRed:MIN(1, r + 0.15) green:MIN(1, g + 0.15) blue:MIN(1, b + 0.15) alpha:1];
        UIColor *bottom = [UIColor colorWithRed:r * 0.8 green:g * 0.8 blue:b * 0.8 alpha:1];
        UIColor *stroke = [UIColor colorWithRed:r * 0.6 green:g * 0.6 blue:b * 0.6 alpha:1];
        return SHRoundedGradientImage(top, bottom, stroke, 8, YES);
    }];
}

- (UIImage *)darkPillImage
{
    return [self cachedImage:@"pill-dark" builder:^UIImage *{
        return SHRoundedGradientImage([UIColor colorWithWhite:0 alpha:0.62], [UIColor colorWithWhite:0 alpha:0.72], nil, 7, NO);
    }];
}

- (UIImage *)barBackgroundImage
{
    return [self cachedImage:@"bar" builder:^UIImage *{
        if (self.dark) return SHBarImage(RGB(62, 62, 66), RGB(36, 36, 40), RGB(15, 15, 17), 44);
        return SHBarImage(RGB(245, 245, 248), RGB(214, 214, 220), RGB(170, 170, 178), 44);
    }];
}

- (UIImage *)textFieldBackgroundImage
{
    return [self cachedImage:@"field" builder:^UIImage *{
        if (self.dark) return SHRoundedGradientImage(RGB(40, 40, 44), RGB(44, 44, 48), RGB(80, 80, 86), 8, NO);
        return SHRoundedGradientImage([UIColor whiteColor], [UIColor whiteColor], RGB(160, 160, 168), 8, NO);
    }];
}

- (UIImage *)buttonImageHighlighted:(BOOL)highlighted
{
    NSString *key = highlighted ? @"button-hi" : @"button";
    return [self cachedImage:key builder:^UIImage *{
        if (self.dark) {
            if (highlighted) return SHRoundedGradientImage(RGB(70, 70, 76), RGB(50, 50, 56), RGB(20, 20, 24), 6, YES);
            return SHRoundedGradientImage(RGB(100, 100, 106), RGB(66, 66, 72), RGB(20, 20, 24), 6, YES);
        }
        if (highlighted) return SHRoundedGradientImage(RGB(200, 203, 212), RGB(170, 174, 186), RGB(120, 124, 136), 6, YES);
        return SHRoundedGradientImage(RGB(250, 250, 252), RGB(214, 216, 225), RGB(140, 144, 156), 6, YES);
    }];
}

- (UIImage *)accentButtonImageHighlighted:(BOOL)highlighted disabled:(BOOL)disabled
{
    NSString *key = [NSString stringWithFormat:@"accent-%d-%d", (int)highlighted, (int)disabled];
    return [self cachedImage:key builder:^UIImage *{
        // the blue glossy button (Follow, Send, Post), like the iOS 6 "Done" keyboard button
        if (disabled) return SHRoundedGradientImage(RGB(190, 190, 196), RGB(160, 160, 168), RGB(140, 140, 148), 7, YES);
        if (highlighted) return SHRoundedGradientImage(RGB(60, 120, 200), RGB(25, 85, 165), RGB(15, 60, 130), 7, YES);
        return SHRoundedGradientImage(RGB(110, 180, 250), RGB(30, 130, 235), RGB(10, 95, 195), 7, YES);
    }];
}

- (UIImage *)redButtonImageHighlighted:(BOOL)highlighted
{
    NSString *key = highlighted ? @"red-hi" : @"red";
    return [self cachedImage:key builder:^UIImage *{
        if (highlighted) return SHRoundedGradientImage(RGB(190, 50, 45), RGB(140, 25, 22), RGB(110, 20, 18), 7, YES);
        return SHRoundedGradientImage(RGB(235, 100, 90), RGB(190, 45, 40), RGB(150, 35, 30), 7, YES);
    }];
}

- (UIImage *)thumbnailPlaceholder
{
    return [self cachedImage:@"thumb" builder:^UIImage *{
        return SHDrawImage(CGSizeMake(64, 36), ^(CGContextRef ctx) {
            SHDrawVerticalGradient(ctx, CGRectMake(0, 0, 64, 36), RGB(70, 70, 78), RGB(40, 40, 46));
            UIBezierPath *play = [UIBezierPath bezierPath];
            [play moveToPoint:CGPointMake(27, 11)];
            [play addLineToPoint:CGPointMake(40, 18)];
            [play addLineToPoint:CGPointMake(27, 25)];
            [play closePath];
            [[UIColor colorWithWhite:1 alpha:0.25] setFill];
            [play fill];
        });
    }];
}

- (UIImage *)boxArtPlaceholder
{
    return [self cachedImage:@"boxart" builder:^UIImage *{
        return SHDrawImage(CGSizeMake(30, 40), ^(CGContextRef ctx) {
            SHDrawVerticalGradient(ctx, CGRectMake(0, 0, 30, 40), RGB(110, 80, 170), RGB(70, 45, 120));
        });
    }];
}

- (UIImage *)avatarPlaceholderWithSize:(CGFloat)size
{
    NSString *key = [NSString stringWithFormat:@"avatar-%.0f", size];
    return [self cachedImage:key builder:^UIImage *{
        return SHDrawImage(CGSizeMake(size, size), ^(CGContextRef ctx) {
            [(self.dark ? RGB(70, 70, 78) : RGB(190, 192, 200)) setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, size, size)] fill];
            [(self.dark ? RGB(110, 110, 120) : RGB(240, 240, 244)) setFill];
            CGFloat head = size * 0.34;
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake((size - head) / 2, size * 0.18, head, head)] fill];
            UIBezierPath *body = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(size * 0.15, size * 0.58, size * 0.7, size * 0.6)];
            CGContextSaveGState(ctx);
            CGContextAddEllipseInRect(ctx, CGRectMake(0, 0, size, size));
            CGContextClip(ctx);
            [body fill];
            CGContextRestoreGState(ctx);
        });
    }];
}

- (UIImage *)sectionHeaderBackgroundImage
{
    return [self cachedImage:@"section" builder:^UIImage *{
        if (self.dark) return SHBarImage(RGB(58, 58, 64), RGB(40, 40, 45), RGB(20, 20, 24), 22);
        return SHBarImage(RGB(176, 188, 206), RGB(144, 159, 184), RGB(110, 125, 150), 22);
    }];
}

- (UIImage *)controlsGradientImageTop:(BOOL)top
{
    NSString *key = top ? @"ctl-top" : @"ctl-bottom";
    return [self cachedImage:key builder:^UIImage *{
        UIImage *image = SHDrawImage(CGSizeMake(4, 64), ^(CGContextRef ctx) {
            UIColor *a = [UIColor colorWithWhite:0 alpha:top ? 0.75 : 0.0], *b = [UIColor colorWithWhite:0 alpha:top ? 0.0 : 0.75];
            SHDrawVerticalGradient(ctx, CGRectMake(0, 0, 4, 64), a, b);
        });
        return SHStretchImage(image, UIEdgeInsetsMake(0, 1, 0, 1));
    }];
}

#pragma mark - Pages

- (UIImage *)pageBackgroundImage
{
    return [self cachedImage:@"page-bg" builder:^UIImage *{
        UIImage *image = SHDrawImage(CGSizeMake(4, 512), ^(CGContextRef ctx) {
            if (self.dark) SHDrawVerticalGradient(ctx, CGRectMake(0, 0, 4, 512), RGB(52, 53, 59), RGB(17, 17, 19));
            else SHDrawVerticalGradient(ctx, CGRectMake(0, 0, 4, 512), RGB(236, 238, 243), RGB(201, 205, 214));
        });
        return SHStretchImage(image, UIEdgeInsetsMake(0, 1, 0, 1));
    }];
}

// Fine grain, the same every time (a fixed seed), light and dark specks a few percent strong
- (UIColor *)grainColor
{
    UIImage *grain = [self cachedImage:@"grain" builder:^UIImage *{
        return SHDrawImage(CGSizeMake(96, 96), ^(CGContextRef ctx) {
            uint32_t seed = 0x9e3779b9u;
            for (int i = 0; i < 2600; i++) {
                seed = seed * 1664525u + 1013904223u;
                CGFloat x = (seed >> 8) % 96;
                seed = seed * 1664525u + 1013904223u;
                CGFloat y = (seed >> 8) % 96;
                seed = seed * 1664525u + 1013904223u;
                BOOL light = (seed >> 9) & 1;
                CGFloat alpha = 0.025 + ((seed >> 12) % 100) / 2500.0;
                CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:light ? 1 : 0 alpha:alpha].CGColor);
                CGContextFillRect(ctx, CGRectMake(x, y, 1, 1));
            }
        });
    }];
    return [UIColor colorWithPatternImage:grain];
}

// A capsule of an exact height (stretchable sideways): glossy grey, or the accent colour when chosen
static UIImage *SHCapsuleImage(UIColor *top, UIColor *bottom, UIColor *stroke, CGFloat height)
{
    CGFloat r = floorf(height / 2), w = r * 2 + 2;
    CGRect rect = CGRectMake(0, 0, w, height);
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(rect, 0.5, 0.5) cornerRadius:r - 0.5];
    CGContextSaveGState(ctx);
    [path addClip];
    SHDrawVerticalGradient(ctx, rect, top, bottom);
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.16].CGColor);    // the shine of the top half
    CGContextFillRect(ctx, CGRectMake(0, 0, w, floorf(height / 2)));
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.35].CGColor);    // and its bright top edge
    CGContextFillRect(ctx, CGRectMake(0, 1, w, 1));
    CGContextRestoreGState(ctx);
    [stroke setStroke];
    path.lineWidth = 1;
    [path stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return SHStretchImage(image, UIEdgeInsetsMake(0, r, 0, r));
}

- (UIImage *)capsuleImageSelected:(BOOL)selected highlighted:(BOOL)highlighted height:(CGFloat)height
{
    NSString *key = [NSString stringWithFormat:@"capsule-%d-%d-%.0f", (int)selected, (int)highlighted, height];
    return [self cachedImage:key builder:^UIImage *{
        if (selected) {
            if (highlighted) return SHCapsuleImage(RGB(220, 60, 90), RGB(160, 14, 46), RGB(100, 8, 30), height);
            return SHCapsuleImage(RGB(255, 98, 126), RGB(206, 24, 62), RGB(128, 12, 40), height);
        }
        if (self.dark) {
            if (highlighted) return SHCapsuleImage(RGB(62, 62, 68), RGB(36, 36, 40), RGB(12, 12, 14), height);
            return SHCapsuleImage(RGB(88, 88, 95), RGB(46, 46, 51), RGB(12, 12, 14), height);
        }
        if (highlighted) return SHCapsuleImage(RGB(208, 212, 222), RGB(180, 185, 197), RGB(130, 134, 146), height);
        return SHCapsuleImage(RGB(255, 255, 255), RGB(220, 223, 230), RGB(150, 154, 166), height);
    }];
}

- (UIImage *)badgeImageWithHeight:(CGFloat)height
{
    return [self cachedImage:[NSString stringWithFormat:@"badge-%.0f", height] builder:^UIImage *{
        return SHCapsuleImage([UIColor colorWithWhite:0.2 alpha:0.72], [UIColor colorWithWhite:0 alpha:0.8], [UIColor colorWithWhite:0 alpha:0.55], height);
    }];
}

- (UIImage *)roundButtonImageWithSize:(CGFloat)size
{
    return [self cachedImage:[NSString stringWithFormat:@"round-%.0f", size] builder:^UIImage *{
        return SHDrawImage(CGSizeMake(size, size), ^(CGContextRef ctx) {
            CGRect all = CGRectMake(0, 0, size, size);
            UIBezierPath *disc = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(all, 1, 1)];
            CGContextSaveGState(ctx);
            [disc addClip];
            SHDrawVerticalGradient(ctx, all, [UIColor colorWithWhite:0.32 alpha:0.85], [UIColor colorWithWhite:0.02 alpha:0.85]);
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.14].CGColor);
            CGContextFillEllipseInRect(ctx, CGRectMake(size * 0.08, -size * 0.38, size * 0.84, size * 0.82));
            CGContextRestoreGState(ctx);
            [[UIColor colorWithWhite:1 alpha:0.75] setStroke];
            disc.lineWidth = 1.5;
            [disc stroke];
        });
    }];
}

- (UIColor *)embossTextColor { return self.dark ? RGB(236, 236, 240) : RGB(52, 56, 66); }

- (void)embossLabel:(UILabel *)label
{
    label.shadowColor = self.dark ? [UIColor colorWithWhite:0 alpha:0.85] : [UIColor colorWithWhite:1 alpha:0.9];
    label.shadowOffset = self.dark ? CGSizeMake(0, -1) : CGSizeMake(0, 1);
}

- (void)embossButton:(UIButton *)button
{
    [self embossLabel:button.titleLabel];
    [button setTitleShadowColor:button.titleLabel.shadowColor forState:UIControlStateNormal];
    button.titleLabel.shadowOffset = button.titleLabel.shadowOffset;
}

#pragma mark - Icons

// Tab bar icons are alpha masks: UIKit colours them itself
- (UIImage *)tabIconHome
{
    return [self cachedImage:@"tab-home" builder:^UIImage *{
        return SHDrawImage(CGSizeMake(30, 30), ^(CGContextRef ctx) {
            [[UIColor blackColor] setFill];
            UIBezierPath *roof = [UIBezierPath bezierPath];
            [roof moveToPoint:CGPointMake(15, 2.5)];
            [roof addLineToPoint:CGPointMake(28.5, 14)];
            [roof addLineToPoint:CGPointMake(24.5, 14)];
            [roof addLineToPoint:CGPointMake(24.5, 27)];
            [roof addLineToPoint:CGPointMake(5.5, 27)];
            [roof addLineToPoint:CGPointMake(5.5, 14)];
            [roof addLineToPoint:CGPointMake(1.5, 14)];
            [roof closePath];
            [roof fill];
            CGContextSetBlendMode(ctx, kCGBlendModeClear);
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(12, 17, 6, 10) cornerRadius:1.5] fill];
        });
    }];
}

- (UIImage *)tabIconSubscriptions
{
    return [self cachedImage:@"tab-subscriptions" builder:^UIImage *{
        return SHDrawImage(CGSizeMake(30, 30), ^(CGContextRef ctx) {
            // three stacked screens, a play sign in the front one
            [[UIColor blackColor] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(7, 2, 16, 3) cornerRadius:1.5] fill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(4.5, 7, 21, 3) cornerRadius:1.5] fill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 12, 26, 16) cornerRadius:3] fill];
            CGContextSetBlendMode(ctx, kCGBlendModeClear);
            UIBezierPath *play = [UIBezierPath bezierPath];
            [play moveToPoint:CGPointMake(12, 15.5)];
            [play addLineToPoint:CGPointMake(20, 20)];
            [play addLineToPoint:CGPointMake(12, 24.5)];
            [play closePath];
            [play fill];
        });
    }];
}

- (UIImage *)tabIconShorts
{
    return [self cachedImage:@"tab-shorts" builder:^UIImage *{
        return SHDrawImage(CGSizeMake(30, 30), ^(CGContextRef ctx) {
            // a phone standing up, a play sign on its screen
            [[UIColor blackColor] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(7.5, 1.5, 15, 27) cornerRadius:3.5] fill];
            CGContextSetBlendMode(ctx, kCGBlendModeClear);
            UIBezierPath *play = [UIBezierPath bezierPath];
            [play moveToPoint:CGPointMake(12.5, 10)];
            [play addLineToPoint:CGPointMake(19.5, 14.5)];
            [play addLineToPoint:CGPointMake(12.5, 19)];
            [play closePath];
            [play fill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(13, 24.5, 4, 1.5) cornerRadius:0.75] fill];
        });
    }];
}

- (UIImage *)tabIconLibrary
{
    return [self cachedImage:@"tab-library" builder:^UIImage *{
        return SHDrawImage(CGSizeMake(30, 30), ^(CGContextRef ctx) {
            // a clock with an arrow around it: history and what was kept for later
            [[UIColor blackColor] setStroke];
            [[UIColor blackColor] setFill];
            UIBezierPath *ring = [UIBezierPath bezierPathWithArcCenter:CGPointMake(15, 16) radius:11 startAngle:-M_PI * 0.35 endAngle:M_PI * 1.45 clockwise:YES];
            ring.lineWidth = 3.5;
            ring.lineCapStyle = kCGLineCapRound;
            [ring stroke];
            UIBezierPath *arrow = [UIBezierPath bezierPath];
            [arrow moveToPoint:CGPointMake(19.5, 1.5)];
            [arrow addLineToPoint:CGPointMake(26, 5.5)];
            [arrow addLineToPoint:CGPointMake(19.5, 10)];
            [arrow closePath];
            [arrow fill];
            UIBezierPath *hands = [UIBezierPath bezierPath];
            [hands moveToPoint:CGPointMake(15, 9)];
            [hands addLineToPoint:CGPointMake(15, 16.5)];
            [hands addLineToPoint:CGPointMake(20.5, 19.5)];
            hands.lineWidth = 3;
            hands.lineCapStyle = kCGLineCapRound;
            hands.lineJoinStyle = kCGLineJoinRound;
            [hands stroke];
        });
    }];
}

- (UIImage *)tabIconSearch
{
    return [self cachedImage:@"tab-search" builder:^UIImage *{
        return SHDrawImage(CGSizeMake(30, 30), ^(CGContextRef ctx) {
            [[UIColor blackColor] setStroke];
            UIBezierPath *lens = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(4, 4, 15, 15)];
            lens.lineWidth = 3.5;
            [lens stroke];
            UIBezierPath *handle = [UIBezierPath bezierPath];
            [handle moveToPoint:CGPointMake(17, 17)];
            [handle addLineToPoint:CGPointMake(26, 26)];
            handle.lineWidth = 4.5;
            handle.lineCapStyle = kCGLineCapRound;
            [handle stroke];
        });
    }];
}

- (UIImage *)gearPathImageSize:(CGFloat)size color:(UIColor *)color
{
    return SHDrawImage(CGSizeMake(size, size), ^(CGContextRef ctx) {
        CGFloat c = size / 2;
        CGContextTranslateCTM(ctx, c, c);
        [color setFill];
        CGFloat outer = size * 0.33, toothW = size * 0.17, toothH = size * 0.14;
        for (int i = 0; i < 8; i++) {
            CGContextSaveGState(ctx);
            CGContextRotateCTM(ctx, i * M_PI / 4);
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(-toothW / 2, -outer - toothH, toothW, toothH + 3) cornerRadius:1.5] fill];
            CGContextRestoreGState(ctx);
        }
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(-outer, -outer, outer * 2, outer * 2)] fill];
        CGContextSetBlendMode(ctx, kCGBlendModeClear);
        CGFloat hole = size * 0.14;
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(-hole, -hole, hole * 2, hole * 2)] fill];
    });
}

- (UIImage *)tabIconSettings
{
    return [self cachedImage:@"tab-settings" builder:^UIImage *{
        return [self gearPathImageSize:30 color:[UIColor blackColor]];
    }];
}

- (UIImage *)playIcon
{
    return [self cachedImage:@"play" builder:^UIImage *{
        return SHDrawImage(CGSizeMake(30, 30), ^(CGContextRef ctx) {
            UIBezierPath *p = [UIBezierPath bezierPath];
            [p moveToPoint:CGPointMake(8, 4)];
            [p addLineToPoint:CGPointMake(26, 15)];
            [p addLineToPoint:CGPointMake(8, 26)];
            [p closePath];
            [[UIColor whiteColor] setFill];
            [p fill];
        });
    }];
}

- (UIImage *)pauseIcon
{
    return [self cachedImage:@"pause" builder:^UIImage *{
        return SHDrawImage(CGSizeMake(30, 30), ^(CGContextRef ctx) {
            [[UIColor whiteColor] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(7, 4, 6, 22) cornerRadius:1] fill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(17, 4, 6, 22) cornerRadius:1] fill];
        });
    }];
}

- (UIImage *)fullscreenIconEnter:(BOOL)enter
{
    NSString *key = enter ? @"fs-enter" : @"fs-exit";
    return [self cachedImage:key builder:^UIImage *{
        return SHDrawImage(CGSizeMake(30, 30), ^(CGContextRef ctx) {
            [[UIColor whiteColor] setStroke];
            UIBezierPath *p = [UIBezierPath bezierPath];
            p.lineWidth = 2.5;
            p.lineCapStyle = kCGLineCapRound;
            p.lineJoinStyle = kCGLineJoinRound;
            CGFloat a = 5, b = 12, c = 18, d = 25;   // outer and inner coordinates
            if (enter) {
                [p moveToPoint:CGPointMake(a, b)]; [p addLineToPoint:CGPointMake(a, a)]; [p addLineToPoint:CGPointMake(b, a)];
                [p moveToPoint:CGPointMake(c, a)]; [p addLineToPoint:CGPointMake(d, a)]; [p addLineToPoint:CGPointMake(d, b)];
                [p moveToPoint:CGPointMake(d, c)]; [p addLineToPoint:CGPointMake(d, d)]; [p addLineToPoint:CGPointMake(c, d)];
                [p moveToPoint:CGPointMake(b, d)]; [p addLineToPoint:CGPointMake(a, d)]; [p addLineToPoint:CGPointMake(a, c)];
            } else {
                [p moveToPoint:CGPointMake(b, a)]; [p addLineToPoint:CGPointMake(b, b)]; [p addLineToPoint:CGPointMake(a, b)];
                [p moveToPoint:CGPointMake(c, a)]; [p addLineToPoint:CGPointMake(c, b)]; [p addLineToPoint:CGPointMake(d, b)];
                [p moveToPoint:CGPointMake(d, c)]; [p addLineToPoint:CGPointMake(c, c)]; [p addLineToPoint:CGPointMake(c, d)];
                [p moveToPoint:CGPointMake(b, d)]; [p addLineToPoint:CGPointMake(b, c)]; [p addLineToPoint:CGPointMake(a, c)];
            }
            [p stroke];
        });
    }];
}

- (UIImage *)chatIconOn:(BOOL)on
{
    NSString *key = on ? @"chat-on" : @"chat-off";
    return [self cachedImage:key builder:^UIImage *{
        return SHDrawImage(CGSizeMake(30, 30), ^(CGContextRef ctx) {
            UIBezierPath *bubble = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(3, 4, 24, 17) cornerRadius:5];
            UIBezierPath *tail = [UIBezierPath bezierPath];
            [tail moveToPoint:CGPointMake(9, 20)];
            [tail addLineToPoint:CGPointMake(7, 27)];
            [tail addLineToPoint:CGPointMake(15, 20.5)];
            [tail closePath];
            [bubble appendPath:tail];
            if (on) {
                [[UIColor whiteColor] setFill];
                [bubble fill];
                CGContextSetBlendMode(ctx, kCGBlendModeClear);
                [[UIColor blackColor] setFill];
                [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(8, 9, 14, 2) cornerRadius:1] fill];
                [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(8, 14, 10, 2) cornerRadius:1] fill];
            } else {
                [[UIColor whiteColor] setStroke];
                bubble.lineWidth = 2;
                bubble.lineJoinStyle = kCGLineJoinRound;
                [bubble stroke];
            }
        });
    }];
}

- (UIImage *)gearIconWhite
{
    return [self cachedImage:@"gear-white" builder:^UIImage *{
        return [self gearPathImageSize:28 color:[UIColor whiteColor]];
    }];
}

- (UIImage *)closeIconWhite
{
    return [self cachedImage:@"close-white" builder:^UIImage *{
        return SHDrawImage(CGSizeMake(24, 24), ^(CGContextRef ctx) {
            UIBezierPath *p = [UIBezierPath bezierPath];
            [p moveToPoint:CGPointMake(6, 6)]; [p addLineToPoint:CGPointMake(18, 18)];
            [p moveToPoint:CGPointMake(18, 6)]; [p addLineToPoint:CGPointMake(6, 18)];
            p.lineWidth = 3;
            p.lineCapStyle = kCGLineCapRound;
            [[UIColor whiteColor] setStroke];
            [p stroke];
        });
    }];
}

- (UIImage *)backChevronWhite
{
    return [self cachedImage:@"back-white" builder:^UIImage *{
        return SHDrawImage(CGSizeMake(24, 24), ^(CGContextRef ctx) {
            UIBezierPath *p = [UIBezierPath bezierPath];
            [p moveToPoint:CGPointMake(16, 3)];
            [p addLineToPoint:CGPointMake(7, 12)];
            [p addLineToPoint:CGPointMake(16, 21)];
            p.lineWidth = 3.5;
            p.lineCapStyle = kCGLineCapRound;
            p.lineJoinStyle = kCGLineJoinRound;
            [[UIColor whiteColor] setStroke];
            [p stroke];
        });
    }];
}

- (UIImage *)minimizeChevronWhite
{
    return [self cachedImage:@"minimize-white" builder:^UIImage *{
        return SHDrawImage(CGSizeMake(24, 24), ^(CGContextRef ctx) {
            UIBezierPath *p = [UIBezierPath bezierPath];
            [p moveToPoint:CGPointMake(5, 9)];
            [p addLineToPoint:CGPointMake(12, 16)];
            [p addLineToPoint:CGPointMake(19, 9)];
            p.lineWidth = 3.5;
            p.lineCapStyle = kCGLineCapRound;
            p.lineJoinStyle = kCGLineJoinRound;
            [[UIColor whiteColor] setStroke];
            [p stroke];
        });
    }];
}

- (UIImage *)replayIcon
{
    return [self cachedImage:@"replay" builder:^UIImage *{
        return SHDrawImage(CGSizeMake(30, 30), ^(CGContextRef ctx) {
            UIBezierPath *arc = [UIBezierPath bezierPathWithArcCenter:CGPointMake(15, 15) radius:9 startAngle:-M_PI * 0.3 endAngle:M_PI * 1.5 clockwise:YES];
            arc.lineWidth = 3;
            arc.lineCapStyle = kCGLineCapRound;
            [[UIColor whiteColor] setStroke];
            [arc stroke];
            UIBezierPath *head = [UIBezierPath bezierPath];
            [head moveToPoint:CGPointMake(18, 1)];
            [head addLineToPoint:CGPointMake(24, 6)];
            [head addLineToPoint:CGPointMake(17, 9)];
            [head closePath];
            [[UIColor whiteColor] setFill];
            [head fill];
        });
    }];
}

- (UIImage *)searchIconWhite
{
    return [self cachedImage:@"search-white" builder:^UIImage *{
        return SHDrawImage(CGSizeMake(28, 28), ^(CGContextRef ctx) {
            [[UIColor whiteColor] setStroke];
            UIBezierPath *lens = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(4, 4, 14, 14)];
            lens.lineWidth = 3;
            [lens stroke];
            UIBezierPath *handle = [UIBezierPath bezierPath];
            [handle moveToPoint:CGPointMake(16.5, 16.5)];
            [handle addLineToPoint:CGPointMake(24, 24)];
            handle.lineWidth = 4;
            handle.lineCapStyle = kCGLineCapRound;
            [handle stroke];
        });
    }];
}

- (UIImage *)discImageWithSize:(CGFloat)size
{
    return [self cachedImage:[NSString stringWithFormat:@"disc-%.0f", size] builder:^UIImage *{
        return SHDrawImage(CGSizeMake(size, size), ^(CGContextRef ctx) {
            CGRect all = CGRectMake(0, 0, size, size);
            [RGB(24, 24, 26) setFill];
            [[UIBezierPath bezierPathWithOvalInRect:all] fill];
            // grooves, and a little shine across them
            [[UIColor colorWithWhite:1 alpha:0.09] setStroke];
            for (CGFloat inset = size * 0.08; inset < size * 0.24; inset += size * 0.05) {
                UIBezierPath *groove = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(all, inset, inset)];
                groove.lineWidth = 1;
                [groove stroke];
            }
            CGContextSaveGState(ctx);
            [[UIBezierPath bezierPathWithOvalInRect:all] addClip];
            CGFloat colors[] = { 1, 1, 1, 0.16, 1, 1, 1, 0 };
            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            CGGradientRef shine = CGGradientCreateWithColorComponents(space, colors, NULL, 2);
            CGContextDrawLinearGradient(ctx, shine, CGPointMake(0, 0), CGPointMake(size * 0.6, size * 0.6), 0);
            CGGradientRelease(shine);
            CGColorSpaceRelease(space);
            CGContextRestoreGState(ctx);
            [[UIColor colorWithWhite:0.45 alpha:1] setStroke];
            UIBezierPath *rim = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(all, 0.75, 0.75)];
            rim.lineWidth = 1.5;
            [rim stroke];
        });
    }];
}

- (UIImage *)starIconFilled:(BOOL)filled color:(UIColor *)color size:(CGFloat)size
{
    CGFloat r = 0, g = 0, b = 0, a = 1;
    [color getRed:&r green:&g blue:&b alpha:&a];
    NSString *key = [NSString stringWithFormat:@"star-%d-%.0f-%.2f-%.2f-%.2f", (int)filled, size, r, g, b];
    return [self cachedImage:key builder:^UIImage *{
        return SHDrawImage(CGSizeMake(size, size), ^(CGContextRef ctx) {
            UIBezierPath *star = [UIBezierPath bezierPath];
            CGFloat cx = size / 2, cy = size / 2 + size * 0.03, outer = size * 0.46, inner = outer * 0.42;
            for (int i = 0; i < 10; i++) {
                CGFloat radius = (i % 2 == 0) ? outer : inner;
                CGFloat angle = -M_PI / 2 + i * M_PI / 5;
                CGPoint p = CGPointMake(cx + radius * cos(angle), cy + radius * sin(angle));
                if (i == 0) [star moveToPoint:p]; else [star addLineToPoint:p];
            }
            [star closePath];
            star.lineJoinStyle = kCGLineJoinRound;
            if (filled) {
                [color setFill];
                [star fill];
            } else {
                [color setStroke];
                star.lineWidth = MAX(1.5, size / 14);
                [star stroke];
            }
        });
    }];
}

- (UIImage *)liveDotImage
{
    return [self cachedImage:@"live-dot" builder:^UIImage *{
        return SHDrawImage(CGSizeMake(10, 10), ^(CGContextRef ctx) {
            [[self liveColor] setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, 8, 8)] fill];
            [[UIColor colorWithWhite:1 alpha:0.45] setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(2.5, 2, 4, 3)] fill];
        });
    }];
}

- (UIImage *)emoteIcon
{
    return [self cachedImage:@"emote" builder:^UIImage *{
        return SHDrawImage(CGSizeMake(26, 26), ^(CGContextRef ctx) {
            UIColor *color = self.dark ? RGB(200, 200, 206) : RGB(90, 90, 98);
            UIBezierPath *face = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(2, 2, 22, 22)];
            face.lineWidth = 2;
            [color setStroke];
            [face stroke];
            [color setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(8, 9, 3, 3)] fill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(15, 9, 3, 3)] fill];
            UIBezierPath *smile = [UIBezierPath bezierPathWithArcCenter:CGPointMake(13, 13.5) radius:6 startAngle:M_PI * 0.15 endAngle:M_PI * 0.85 clockwise:YES];
            smile.lineWidth = 2;
            smile.lineCapStyle = kCGLineCapRound;
            [smile stroke];
        });
    }];
}

- (UIImage *)checkmarkImage
{
    return [self cachedImage:@"check" builder:^UIImage *{
        return SHDrawImage(CGSizeMake(18, 18), ^(CGContextRef ctx) {
            UIBezierPath *p = [UIBezierPath bezierPath];
            [p moveToPoint:CGPointMake(3, 9.5)];
            [p addLineToPoint:CGPointMake(7.5, 14)];
            [p addLineToPoint:CGPointMake(15.5, 4)];
            p.lineWidth = 3;
            p.lineCapStyle = kCGLineCapRound;
            p.lineJoinStyle = kCGLineJoinRound;
            [[self accentColor] setStroke];
            [p stroke];
        });
    }];
}

- (UIImage *)disclosureChevronImage
{
    return [self cachedImage:@"chevron" builder:^UIImage *{
        return SHDrawImage(CGSizeMake(12, 20), ^(CGContextRef ctx) {
            UIBezierPath *p = [UIBezierPath bezierPath];
            [p moveToPoint:CGPointMake(3, 4)];
            [p addLineToPoint:CGPointMake(9, 10)];
            [p addLineToPoint:CGPointMake(3, 16)];
            p.lineWidth = 2.5;
            p.lineCapStyle = kCGLineCapRound;
            p.lineJoinStyle = kCGLineJoinRound;
            [(self.dark ? RGB(130, 130, 138) : RGB(160, 160, 168)) setStroke];
            [p stroke];
        });
    }];
}

#pragma mark - iOS 6 surfaces

// The woven linen of iOS 6: short threads, each a shade lighter or darker than the base, run along every row and
// down every column, the warp fainter than the weft, with slubs scattered over them. Threads are short (3-14
// points) so that no line runs across the screen, and the tile repeats without a seam or a visible grid.
- (UIColor *)linenColor
{
    UIImage *tile = [self cachedImage:@"linen2" builder:^UIImage *{
        const int side = 128;
        return SHDrawImage(CGSizeMake(side, side), ^(CGContextRef ctx) {
            [(self.dark ? RGB(31, 32, 35) : RGB(216, 219, 225)) setFill];
            CGContextFillRect(ctx, CGRectMake(0, 0, side, side));
            uint32_t seed = 0x2545F491u;
            for (int pass = 0; pass < 2; pass++) {
                CGFloat strength = pass == 0 ? (self.dark ? 0.055 : 0.07) : (self.dark ? 0.035 : 0.045);   // weft, then warp
                for (int line = 0; line < side; line++) {
                    int along = 0;
                    while (along < side) {
                        seed = seed * 1664525u + 1013904223u;
                        int length = 3 + (int)((seed >> 8) % 12);
                        if (along + length > side) length = side - along;
                        seed = seed * 1664525u + 1013904223u;
                        BOOL light = (seed >> 10) & 1;
                        CGFloat alpha = strength * (((seed >> 12) % 100) / 100.0);
                        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:light ? 1 : 0 alpha:alpha].CGColor);
                        CGContextFillRect(ctx, pass == 0 ? CGRectMake(along, line, length, 1) : CGRectMake(line, along, 1, length));
                        along += length;
                    }
                }
            }
            for (int i = 0; i < 2400; i++) {
                seed = seed * 1664525u + 1013904223u;
                CGFloat x = (seed >> 8) % side;
                seed = seed * 1664525u + 1013904223u;
                CGFloat y = (seed >> 8) % side;
                seed = seed * 1664525u + 1013904223u;
                BOOL light = (seed >> 9) & 1;
                CGFloat alpha = 0.02 + ((seed >> 12) % 100) / 2500.0;
                CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:light ? 1 : 0 alpha:alpha].CGColor);
                CGContextFillRect(ctx, CGRectMake(x, y, 1, 1));
            }
        });
    }];
    return [UIColor colorWithPatternImage:tile];
}

- (UIView *)texturedBackgroundView
{
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 480)];
    v.backgroundColor = [self linenColor];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    return v;
}

// A row: a soft vertical gradient between a light top line and a dark bottom line, so that two rows meet in an
// etched groove (the lines of a plain list on iOS 6 are part of the rows, not hairlines drawn between them).
static UIImage *SHRowImage(UIColor *top, UIColor *bottom, UIColor *highlight, UIColor *shadow)
{
    UIImage *image = SHDrawImage(CGSizeMake(4, 44), ^(CGContextRef ctx) {
        SHDrawVerticalGradient(ctx, CGRectMake(0, 0, 4, 44), top, bottom);
        [highlight setFill];
        UIRectFill(CGRectMake(0, 0, 4, 1));
        [shadow setFill];
        UIRectFill(CGRectMake(0, 43, 4, 1));
    });
    return SHStretchImage(image, UIEdgeInsetsMake(2, 1, 2, 1));
}

- (UIImage *)cellBackgroundImage
{
    return [self cachedImage:@"row" builder:^UIImage *{
        if (self.dark) return SHRowImage(RGB(45, 46, 50), RGB(35, 36, 39), [UIColor colorWithWhite:1 alpha:0.075], [UIColor colorWithWhite:0 alpha:0.8]);
        return SHRowImage(RGB(255, 255, 255), RGB(239, 240, 243), [UIColor whiteColor], RGB(196, 198, 205));
    }];
}

- (UIImage *)cellSelectedBackgroundImage
{
    return [self cachedImage:@"row-selected" builder:^UIImage *{
        return SHRowImage(RGB(5, 140, 245), RGB(1, 93, 230), [UIColor colorWithWhite:1 alpha:0.3], RGB(0, 58, 158));
    }];
}

- (UIImage *)headerBarImage
{
    return [self cachedImage:@"header-bar" builder:^UIImage *{
        if (self.dark) return SHBarImage(RGB(63, 64, 69), RGB(36, 37, 41), RGB(10, 10, 12), 48);
        return SHBarImage(RGB(250, 250, 252), RGB(221, 223, 229), RGB(176, 178, 186), 48);
    }];
}

- (CGFloat)bubbleTailWidth { return 6; }

// The glossy bubbles of iOS 6 Messages: a gradient body, a highlight over the upper half, a darker rim, and the
// tail swept out of the bottom corner on the speaker's side. Stretchable around a small middle.
- (UIImage *)bubbleImageOutgoing:(BOOL)outgoing
{
    return [self bubbleImageOutgoing:outgoing palette:0];
}

- (UIColor *)conversationBackground:(NSInteger)palette
{
    if (palette == 1) return self.dark ? RGB(22, 34, 49) : RGB(222, 235, 248);
    if (palette == 2) return self.dark ? RGB(23, 39, 33) : RGB(226, 241, 229);
    if (palette == 3) return self.dark ? RGB(39, 28, 49) : RGB(238, 228, 246);
    return [self linenColor];
}

- (UIImage *)bubbleImageOutgoing:(BOOL)outgoing palette:(NSInteger)palette
{
    NSString *key = [NSString stringWithFormat:@"bubble-%d-%ld", outgoing, (long)palette];
    return [self cachedImage:key builder:^UIImage *{
        CGFloat r = 14, tail = [self bubbleTailWidth], w = r * 2 + tail + 8, h = r * 2 + 6;
        CGFloat x0 = 0.5, x1 = w - tail - 0.5, y0 = 0.5, y1 = h - 0.5;
        UIBezierPath *path = [UIBezierPath bezierPath];
        [path moveToPoint:CGPointMake(x0 + r, y0)];
        [path addLineToPoint:CGPointMake(x1 - r, y0)];
        [path addArcWithCenter:CGPointMake(x1 - r, y0 + r) radius:r startAngle:-M_PI_2 endAngle:0 clockwise:YES];
        [path addLineToPoint:CGPointMake(x1, y1 - 10)];
        [path addQuadCurveToPoint:CGPointMake(w - 0.5, y1) controlPoint:CGPointMake(x1, y1 - 1)];   // the tail
        [path addLineToPoint:CGPointMake(x0 + r, y1)];
        [path addArcWithCenter:CGPointMake(x0 + r, y1 - r) radius:r startAngle:M_PI_2 endAngle:M_PI clockwise:YES];
        [path addLineToPoint:CGPointMake(x0, y0 + r)];
        [path addArcWithCenter:CGPointMake(x0 + r, y0 + r) radius:r startAngle:M_PI endAngle:M_PI * 1.5 clockwise:YES];
        [path closePath];
        if (!outgoing) [path applyTransform:CGAffineTransformMake(-1, 0, 0, 1, w, 0)];

        UIColor *top, *bottom, *rim;
        CGFloat gloss;
        if (outgoing) { top = RGB(96, 178, 255); bottom = RGB(20, 108, 228); rim = RGB(12, 74, 166); gloss = 0.36; }
        else if (self.dark) { top = RGB(86, 87, 94); bottom = RGB(55, 56, 62); rim = RGB(20, 20, 24); gloss = 0.17; }
        else { top = RGB(243, 243, 246); bottom = RGB(217, 218, 225); rim = RGB(168, 170, 178); gloss = 0.7; }
        if (outgoing && palette == 2) { top = RGB(66, 152, 113); bottom = RGB(24, 102, 67); rim = RGB(15, 68, 43); }
        if (outgoing && palette == 3) { top = RGB(151, 107, 192); bottom = RGB(100, 59, 148); rim = RGB(66, 37, 99); }

        UIImage *image = SHDrawImage(CGSizeMake(w, h), ^(CGContextRef ctx) {
            CGContextSaveGState(ctx);
            [path addClip];
            SHDrawVerticalGradient(ctx, CGRectMake(0, 0, w, h), top, bottom);
            CGFloat colors[] = { 1, 1, 1, gloss, 1, 1, 1, 0 };
            CGFloat locations[] = { 0, 1 };
            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            CGGradientRef shine = CGGradientCreateWithColorComponents(space, colors, locations, 2);
            CGContextDrawLinearGradient(ctx, shine, CGPointMake(0, 1), CGPointMake(0, h * 0.55), 0);
            CGGradientRelease(shine);
            CGColorSpaceRelease(space);
            CGContextRestoreGState(ctx);
            [rim setStroke];
            path.lineWidth = 1;
            [path stroke];
        });
        CGFloat near = r + 1, far = r + tail + 1;
        UIEdgeInsets caps = outgoing ? UIEdgeInsetsMake(r + 1, near, r + 1, far) : UIEdgeInsetsMake(r + 1, far, r + 1, near);
        return SHStretchImage(image, caps);
    }];
}

- (UIImage *)statBoxImage
{
    return [self cachedImage:@"stat-box" builder:^UIImage *{
        if (self.dark) return SHRoundedGradientImage(RGB(56, 57, 62), RGB(36, 37, 41), RGB(14, 14, 16), 7, YES);
        return SHRoundedGradientImage(RGB(253, 253, 254), RGB(226, 228, 234), RGB(168, 171, 180), 7, YES);
    }];
}

- (UIImage *)storyRingImageWithSize:(CGFloat)size seen:(BOOL)seen
{
    NSString *key = [NSString stringWithFormat:@"ring-%.0f-%d", size, (int)seen];
    return [self cachedImage:key builder:^UIImage *{
        return SHDrawImage(CGSizeMake(size, size), ^(CGContextRef ctx) {
            CGRect all = CGRectMake(0, 0, size, size);
            CGFloat width = seen ? 2 : 3;
            UIBezierPath *ring = [UIBezierPath bezierPathWithOvalInRect:all];
            [ring appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectInset(all, width, width)]];
            ring.usesEvenOddFillRule = YES;
            CGContextSaveGState(ctx);
            [ring addClip];
            if (seen) {
                SHDrawVerticalGradient(ctx, all, self.dark ? RGB(112, 112, 120) : RGB(190, 192, 200), self.dark ? RGB(68, 68, 74) : RGB(150, 152, 160));
            } else {
                CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
                NSArray *colors = @[ (id)RGB(254, 214, 110).CGColor, (id)RGB(250, 122, 32).CGColor, (id)RGB(216, 40, 118).CGColor, (id)RGB(148, 48, 192).CGColor ];
                CGFloat locations[4] = { 0, 0.3, 0.65, 1 };
                CGGradientRef g = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, locations);
                CGContextDrawLinearGradient(ctx, g, CGPointMake(0, size), CGPointMake(size, 0), 0);
                CGGradientRelease(g);
                CGColorSpaceRelease(space);
            }
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.3].CGColor);   // the gloss of the upper half
            CGContextFillRect(ctx, CGRectMake(0, 0, size, size * 0.45));
            CGContextRestoreGState(ctx);
        });
    }];
}

- (void)styleAvatar:(UIView *)view radius:(CGFloat)radius
{
    view.layer.cornerRadius = radius;
    view.layer.masksToBounds = YES;
    view.layer.borderWidth = 1;
    view.layer.borderColor = (self.dark ? [UIColor colorWithWhite:0 alpha:0.8] : [UIColor colorWithWhite:0 alpha:0.22]).CGColor;
    view.backgroundColor = self.dark ? RGB(58, 59, 64) : RGB(205, 207, 214);
}

- (UIFont *)logoFontOfSize:(CGFloat)size
{
    return [UIFont fontWithName:@"SnellRoundhand-Bold" size:size] ?: [UIFont boldSystemFontOfSize:floorf(size * 0.8f)];
}

- (UIView *)logoTitleView
{
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 160, 40)];
    label.text = @"Gramify";
    label.font = [self logoFontOfSize:26];
    label.textColor = [UIColor whiteColor];
    label.backgroundColor = [UIColor clearColor];
    label.textAlignment = UITextAlignmentCenter;
    label.shadowColor = [UIColor colorWithWhite:0 alpha:0.6];
    label.shadowOffset = CGSizeMake(0, -1);
    return label;
}

#pragma mark - Glyphs

// Draws a glyph with a soft dark shadow under it, like the icons of iOS 6 over pictures and on bars.
static UIImage *SHShadowedGlyph(CGSize size, void (^draw)(CGContextRef ctx))
{
    return SHDrawImage(CGSizeMake(size.width + 2, size.height + 3), ^(CGContextRef ctx) {
        CGContextSetShadowWithColor(ctx, CGSizeMake(0, -1), 1.5, [UIColor colorWithWhite:0 alpha:0.7].CGColor);
        CGContextTranslateCTM(ctx, 1, 1);
        draw(ctx);
    });
}

- (UIImage *)playGlyphWithSize:(CGFloat)size
{
    return [self cachedImage:[NSString stringWithFormat:@"g-play-%.0f", size] builder:^UIImage *{
        return SHShadowedGlyph(CGSizeMake(size, size), ^(CGContextRef ctx) {
            UIBezierPath *p = [UIBezierPath bezierPath];
            [p moveToPoint:CGPointMake(size * 0.24, size * 0.12)];
            [p addLineToPoint:CGPointMake(size * 0.9, size * 0.5)];
            [p addLineToPoint:CGPointMake(size * 0.24, size * 0.88)];
            [p closePath];
            p.lineJoinStyle = kCGLineJoinRound;
            p.lineWidth = MAX(1, size / 12);
            [[UIColor whiteColor] setFill];
            [[UIColor whiteColor] setStroke];
            [p fill];
            [p stroke];
        });
    }];
}

- (UIImage *)pauseGlyphWithSize:(CGFloat)size
{
    return [self cachedImage:[NSString stringWithFormat:@"g-pause-%.0f", size] builder:^UIImage *{
        return SHShadowedGlyph(CGSizeMake(size, size), ^(CGContextRef ctx) {
            [[UIColor whiteColor] setFill];
            CGFloat bar = size * 0.26;
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(size * 0.18, size * 0.12, bar, size * 0.76) cornerRadius:size * 0.06] fill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(size * 0.56, size * 0.12, bar, size * 0.76) cornerRadius:size * 0.06] fill];
        });
    }];
}

- (UIImage *)playButtonImageWithSize:(CGFloat)size
{
    return [self cachedImage:[NSString stringWithFormat:@"play-button-%.0f", size] builder:^UIImage *{
        UIImage *disc = [self roundButtonImageWithSize:size];
        UIImage *glyph = [self playGlyphWithSize:floorf(size * 0.42f)];
        return SHDrawImage(CGSizeMake(size, size), ^(CGContextRef ctx) {
            [disc drawAtPoint:CGPointZero];
            [glyph drawAtPoint:CGPointMake(floorf((size - glyph.size.width) / 2 + size * 0.04f), floorf((size - glyph.size.height) / 2))];
        });
    }];
}

- (UIImage *)voiceButtonImagePlaying:(BOOL)playing
{
    return [self cachedImage:playing ? @"voice-pause" : @"voice-play" builder:^UIImage *{
        CGFloat size = 32;
        UIImage *disc = [self roundButtonImageWithSize:size];
        UIImage *glyph = playing ? [self pauseGlyphWithSize:13] : [self playGlyphWithSize:13];
        return SHDrawImage(CGSizeMake(size, size), ^(CGContextRef ctx) {
            [disc drawAtPoint:CGPointZero];
            [glyph drawAtPoint:CGPointMake(floorf((size - glyph.size.width) / 2 + (playing ? 0 : 1)), floorf((size - glyph.size.height) / 2))];
        });
    }];
}

- (UIImage *)voiceTrackImageFilled:(BOOL)filled
{
    return [self cachedImage:filled ? @"track-on" : @"track-off" builder:^UIImage *{
        UIImage *image = SHDrawImage(CGSizeMake(10, 6), ^(CGContextRef ctx) {
            UIBezierPath *groove = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.5, 0.5, 9, 4) cornerRadius:2];
            if (filled) {
                CGContextSaveGState(ctx);
                [groove addClip];
                SHDrawVerticalGradient(ctx, CGRectMake(0, 0, 10, 5), [UIColor whiteColor], RGB(200, 210, 225));
                CGContextRestoreGState(ctx);
            } else {
                [[UIColor colorWithWhite:0 alpha:0.4] setFill];
                [groove fill];
                [[UIColor colorWithWhite:1 alpha:0.18] setFill];   // the light edge under the groove
                UIRectFill(CGRectMake(2, 5, 6, 1));
            }
        });
        return SHStretchImage(image, UIEdgeInsetsMake(0, 3, 0, 3));
    }];
}

- (UIImage *)lockGlyph
{
    return [self cachedImage:@"g-lock" builder:^UIImage *{
        UIColor *color = [self secondaryTextColor];
        return SHDrawImage(CGSizeMake(12, 14), ^(CGContextRef ctx) {
            UIBezierPath *shackle = [UIBezierPath bezierPathWithArcCenter:CGPointMake(6, 5.5) radius:3.2 startAngle:M_PI endAngle:0 clockwise:YES];
            [shackle addLineToPoint:CGPointMake(9.2, 7)];
            [shackle moveToPoint:CGPointMake(2.8, 5.5)];
            [shackle addLineToPoint:CGPointMake(2.8, 7)];
            shackle.lineWidth = 1.6;
            [color setStroke];
            [shackle stroke];
            [color setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(1, 7, 10, 7) cornerRadius:1.5] fill];
        });
    }];
}

- (UIImage *)verifiedBadgeWithSize:(CGFloat)size
{
    return [self cachedImage:[NSString stringWithFormat:@"verified-%.0f", size] builder:^UIImage *{
        return SHDrawImage(CGSizeMake(size, size), ^(CGContextRef ctx) {
            CGRect all = CGRectMake(0.5, 0.5, size - 1, size - 1);
            UIBezierPath *disc = [UIBezierPath bezierPathWithOvalInRect:all];
            CGContextSaveGState(ctx);
            [disc addClip];
            SHDrawVerticalGradient(ctx, all, RGB(92, 176, 255), RGB(16, 110, 228));
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.25].CGColor);
            CGContextFillRect(ctx, CGRectMake(0, 0, size, size * 0.45));
            CGContextRestoreGState(ctx);
            [RGB(10, 76, 170) setStroke];
            disc.lineWidth = 1;
            [disc stroke];
            UIBezierPath *check = [UIBezierPath bezierPath];
            [check moveToPoint:CGPointMake(size * 0.27, size * 0.52)];
            [check addLineToPoint:CGPointMake(size * 0.44, size * 0.68)];
            [check addLineToPoint:CGPointMake(size * 0.74, size * 0.34)];
            check.lineWidth = MAX(1.5, size / 7);
            check.lineCapStyle = kCGLineCapRound;
            check.lineJoinStyle = kCGLineJoinRound;
            [[UIColor whiteColor] setStroke];
            [check stroke];
        });
    }];
}

- (UIImage *)clockGlyph
{
    return [self cachedImage:@"g-clock" builder:^UIImage *{
        UIColor *color = [self secondaryTextColor];
        return SHDrawImage(CGSizeMake(12, 12), ^(CGContextRef ctx) {
            UIBezierPath *face = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, 10, 10)];
            face.lineWidth = 1.3;
            [color setStroke];
            [face stroke];
            UIBezierPath *hands = [UIBezierPath bezierPath];
            [hands moveToPoint:CGPointMake(6, 3.2)];
            [hands addLineToPoint:CGPointMake(6, 6)];
            [hands addLineToPoint:CGPointMake(8.2, 7.3)];
            hands.lineWidth = 1.2;
            hands.lineCapStyle = kCGLineCapRound;
            [hands stroke];
        });
    }];
}

- (UIImage *)carouselGlyph
{
    return [self cachedImage:@"g-carousel" builder:^UIImage *{
        return SHShadowedGlyph(CGSizeMake(16, 16), ^(CGContextRef ctx) {
            [[UIColor whiteColor] setStroke];
            [[UIColor whiteColor] setFill];
            UIBezierPath *back = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(5, 1, 10, 10) cornerRadius:2];
            back.lineWidth = 1.5;
            [back stroke];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(1, 5, 10, 10) cornerRadius:2] fill];
        });
    }];
}

- (UIImage *)videoGlyph
{
    return [self cachedImage:@"g-video" builder:^UIImage *{
        return SHShadowedGlyph(CGSizeMake(18, 14), ^(CGContextRef ctx) {
            [[UIColor whiteColor] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 2, 12, 10) cornerRadius:2] fill];   // a movie camera
            UIBezierPath *lens = [UIBezierPath bezierPath];
            [lens moveToPoint:CGPointMake(12.5, 7)];
            [lens addLineToPoint:CGPointMake(18, 3)];
            [lens addLineToPoint:CGPointMake(18, 11)];
            [lens closePath];
            [lens fill];
        });
    }];
}

- (UIImage *)gearBarIcon
{
    return [self cachedImage:@"gear-bar" builder:^UIImage *{
        return [self gearPathImageSize:20 color:[UIColor whiteColor]];
    }];
}

- (UIImage *)unreadDotImage
{
    return [self cachedImage:@"unread-dot" builder:^UIImage *{
        return SHDrawImage(CGSizeMake(12, 12), ^(CGContextRef ctx) {
            CGRect all = CGRectMake(0.5, 0.5, 11, 11);
            UIBezierPath *dot = [UIBezierPath bezierPathWithOvalInRect:all];
            CGContextSaveGState(ctx);
            [dot addClip];
            SHDrawVerticalGradient(ctx, all, RGB(110, 186, 255), RGB(8, 100, 222));
            CGContextRestoreGState(ctx);
            [RGB(6, 70, 160) setStroke];
            dot.lineWidth = 1;
            [dot stroke];
            [[UIColor colorWithWhite:1 alpha:0.55] setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(3, 1.8, 6, 3.6)] fill];
        });
    }];
}

#pragma mark - Fonts

- (UIFont *)titleFont { return [UIFont boldSystemFontOfSize:SHIsPad() ? 16 : 15]; }
- (UIFont *)bodyFont { return [UIFont systemFontOfSize:SHIsPad() ? 15 : 14]; }
- (UIFont *)smallFont { return [UIFont systemFontOfSize:SHIsPad() ? 13 : 12]; }
- (UIFont *)tinyBoldFont { return [UIFont boldSystemFontOfSize:11]; }

- (CGFloat)chatFontSize
{
    return SHIsPad() ? 15 : 14;
}

- (UIFont *)chatFont { return [UIFont systemFontOfSize:[self chatFontSize]]; }
- (UIFont *)chatBoldFont { return [UIFont boldSystemFontOfSize:[self chatFontSize]]; }
- (UIFont *)chatSmallFont { return [UIFont systemFontOfSize:[self chatFontSize] - 2]; }

#pragma mark - UIKit

- (UIBarStyle)barStyle { return self.dark ? UIBarStyleBlack : UIBarStyleDefault; }
// (on iOS 7 and newer the status bar lies over the bar, which is dark in both looks: light text there)
- (UIStatusBarStyle)statusBarStyle { return SHModernStatusBarStyle(self.dark ? UIStatusBarStyleBlackOpaque : UIStatusBarStyleDefault); }
- (UIActivityIndicatorViewStyle)spinnerStyle { return self.dark ? UIActivityIndicatorViewStyleWhite : UIActivityIndicatorViewStyleGray; }

- (void)applyToNavigationBar:(UINavigationBar *)bar
{
    bar.barStyle = [self barStyle];
    bar.translucent = NO;
    bar.tintColor = nil;
    SHModernStyleNavigationBar(bar);   // iOS 7+: the glossy iOS 6 bar UIKit no longer draws
}

- (void)applyToToolbar:(UIToolbar *)bar
{
    bar.barStyle = [self barStyle];
    bar.translucent = NO;
    bar.tintColor = nil;
    SHModernStyleToolbar(bar);
}

- (void)applyToTabBar:(UITabBar *)bar
{
    // (the tab bar of iOS 6 is black glass in both looks; the selected tab shines blue on its own)
    bar.tintColor = nil;
    SHModernStyleTabBar(bar);
}

- (void)applyToTableView:(UITableView *)tableView
{
    // The linen of iOS 6 behind every list. (An empty plain UITableView draws white on iOS 6 no matter the
    // backgroundColor; the backgroundView fills it even with no rows, so no screen ever flashes white.)
    tableView.backgroundView = [self texturedBackgroundView];
    tableView.backgroundColor = [self backgroundColor];
    // A zero-row plain table with no header/footer paints white on iOS 6; an empty footer makes it honour the
    // background and also hides the trailing separator lines.
    if (!tableView.tableFooterView) tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    // Plain lists take their etched lines from the rows themselves (styleCell:); grouped ones keep UIKit's.
    if (tableView.style == UITableViewStylePlain) tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    tableView.separatorColor = [self separatorColor];
    tableView.indicatorStyle = self.dark ? UIScrollViewIndicatorStyleWhite : UIScrollViewIndicatorStyleDefault;
    SHModernSetTableViewDark(tableView, [self isDark]);
}

- (void)styleCell:(UITableViewCell *)cell
{
    if (![cell.backgroundView isKindOfClass:[UIImageView class]] || ((UIImageView *)cell.backgroundView).image != [self cellBackgroundImage]) {
        cell.backgroundView = [[UIImageView alloc] initWithImage:[self cellBackgroundImage]];
        cell.selectedBackgroundView = [[UIImageView alloc] initWithImage:[self cellSelectedBackgroundImage]];
    }
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    cell.textLabel.textColor = [self primaryTextColor];
    cell.textLabel.highlightedTextColor = [UIColor whiteColor];
    cell.textLabel.backgroundColor = [UIColor clearColor];
    [self embossLabel:cell.textLabel];
    cell.detailTextLabel.textColor = self.dark ? [self secondaryTextColor] : RGB(56, 84, 135);
    cell.detailTextLabel.highlightedTextColor = [UIColor whiteColor];
    cell.detailTextLabel.backgroundColor = [UIColor clearColor];
}

- (void)styleGroupedCell:(UITableViewCell *)cell
{
    cell.backgroundColor = [self cardColor];
    cell.textLabel.textColor = [self primaryTextColor];
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.detailTextLabel.textColor = self.dark ? [self secondaryTextColor] : RGB(56, 84, 135);
    cell.detailTextLabel.backgroundColor = [UIColor clearColor];
    cell.selectedBackgroundView = nil;   // (UIKit's own blue selection of a grouped row)
}

- (void)applyToSearchBar:(UISearchBar *)bar
{
    bar.barStyle = [self barStyle];
    bar.tintColor = nil;
    SHModernStyleSearchBar(bar);
}

@end
