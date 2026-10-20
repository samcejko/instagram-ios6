#import "SHLegacyCollections.h"
NSString * const SHTextFontAttributeName = @"SHTextFont";
NSString * const SHTextColorAttributeName = @"SHTextColor";
#import "SHLinkLabel.h"
#import "SHLinkRouter.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHModern.h"
#import "SHCommon.h"
#import <CoreText/CoreText.h>

@implementation SHTextLink
@end

#pragma mark - Core Text

// One laid-out text for a width and a number of lines: its lines, where each one sits, and its size.
@interface SHTextLayout : NSObject
@property (nonatomic) CGFloat width;
@property (nonatomic) NSInteger maxLines;
@property (nonatomic) CGSize size;
@property (nonatomic, strong) NSArray *lines;      // CTLineRef
@property (nonatomic, strong) NSArray *origins;    // NSValue CGPoint: x of the pen, y of the baseline from the top
@property (nonatomic, strong) NSArray *offsets;    // NSNumber: what a line's string indices count from (a cut last line)
@property (nonatomic, strong) NSArray *ascents;    // NSNumber
@property (nonatomic, strong) NSArray *descents;
@end
@implementation SHTextLayout
@end

// A UIFont as Core Text takes it: the same object from iOS 7 on (they are bridged), a CTFont made by name on iOS 6.
static id SHCTFont(UIFont *font)
{
    if (SHModernIOS()) return font;
    static NSMutableDictionary *made;
    if (!made) made = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%@|%.2f", font.fontName, font.pointSize];
    id f = [made objectForKey:key];
    if (!f) {
        f = (__bridge_transfer id)CTFontCreateWithName((__bridge CFStringRef)font.fontName, font.pointSize, NULL);
        if (f) SHLegacyDictionarySet(made, key, f);
    }
    return f;
}

static id SHParagraph(UITextAlignment alignment)
{
    static NSMutableDictionary *styles;
    if (!styles) styles = [NSMutableDictionary dictionary];
    NSNumber *key = @(alignment);
    id style = [styles objectForKey:key];
    if (!style) {
        CTTextAlignment a = alignment == UITextAlignmentCenter ? kCTCenterTextAlignment
                          : alignment == UITextAlignmentRight ? kCTRightTextAlignment : kCTLeftTextAlignment;
        CTLineBreakMode lb = kCTLineBreakByWordWrapping;
        CTParagraphStyleSetting settings[2] = {
            { kCTParagraphStyleSpecifierAlignment, sizeof(a), &a },
            { kCTParagraphStyleSpecifierLineBreakMode, sizeof(lb), &lb },
        };
        style = (__bridge_transfer id)CTParagraphStyleCreate(settings, 2);
        SHLegacyDictionarySet(styles, key, style);
    }
    return style;
}

static CGFloat SHFlushFactor(UITextAlignment alignment)
{
    return alignment == UITextAlignmentCenter ? 0.5f : alignment == UITextAlignmentRight ? 1.0f : 0;
}

// The text with Core Text's attributes (CTFont, CGColor, the paragraph), the links in their colour.
static NSAttributedString *SHCoreTextString(NSAttributedString *text, UIFont *font, UIColor *color, UIColor *linkColor,
                                            NSArray *links, UITextAlignment alignment)
{
    NSString *s = text.string ?: @"";
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] initWithString:s];
    if (!s.length) return out;
    id paragraph = SHParagraph(alignment);
    NSString *fontKey = (__bridge NSString *)kCTFontAttributeName;
    NSString *colorKey = (__bridge NSString *)kCTForegroundColorAttributeName;
    NSString *paragraphKey = (__bridge NSString *)kCTParagraphStyleAttributeName;
    [text enumerateAttributesInRange:NSMakeRange(0, s.length) options:0 usingBlock:^(NSDictionary *attrs, NSRange range, BOOL *stop) {
        UIFont *f = [[attrs objectForKey:SHTextFontAttributeName] isKindOfClass:[UIFont class]] ? [attrs objectForKey:SHTextFontAttributeName] : font;
        UIColor *c = [[attrs objectForKey:SHTextColorAttributeName] isKindOfClass:[UIColor class]] ? [attrs objectForKey:SHTextColorAttributeName] : color;
        id ctFont = SHCTFont(f);
        NSMutableDictionary *a = [NSMutableDictionary dictionaryWithObject:paragraph forKey:paragraphKey];
        if (ctFont) SHLegacyDictionarySet(a, fontKey, ctFont);
        if (c) SHLegacyDictionarySet(a, colorKey, (__bridge id)c.CGColor);
        [out setAttributes:a range:range];
    }];
    if (linkColor) {
        for (SHTextLink *l in links) {
            if (l.kind == SHTextLinkUser) continue;   // (the name keeps the look it was given)
            if (NSMaxRange(l.range) <= s.length) [out addAttribute:colorKey value:(__bridge id)linkColor.CGColor range:l.range];
        }
    }
    return out;
}

static SHTextLayout *SHLayoutText(NSAttributedString *ct, CGFloat width, NSInteger maxLines, UITextAlignment alignment)
{
    SHTextLayout *layout = [[SHTextLayout alloc] init];
    layout.width = width;
    layout.maxLines = maxLines;
    NSMutableArray *lines = [NSMutableArray array], *origins = [NSMutableArray array], *offsets = [NSMutableArray array];
    NSMutableArray *ascents = [NSMutableArray array], *descents = [NSMutableArray array];
    layout.lines = lines; layout.origins = origins; layout.offsets = offsets; layout.ascents = ascents; layout.descents = descents;
    if (!ct.length || width <= 1) return layout;

    const CGFloat tall = 100000;
    CTFramesetterRef setter = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)ct);
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddRect(path, NULL, CGRectMake(0, 0, width, tall));
    CTFrameRef frame = CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, NULL);
    CFArrayRef all = CTFrameGetLines(frame);
    CFIndex count = CFArrayGetCount(all);
    CFIndex shown = maxLines > 0 ? MIN(count, (CFIndex)maxLines) : count;
    CGPoint *points = malloc(sizeof(CGPoint) * (size_t)MAX(shown, (CFIndex)1));
    if (shown > 0) CTFrameGetLineOrigins(frame, CFRangeMake(0, shown), points);

    CGFloat widest = 0, bottom = 0;
    for (CFIndex i = 0; i < shown; i++) {
        CTLineRef line = (CTLineRef)CFArrayGetValueAtIndex(all, i);
        id keep = (__bridge id)line;
        NSUInteger offset = 0;
        CGFloat x = points[i].x;
        if (i == shown - 1 && shown < count) {
            // the last line allowed: the rest of the text on it, cut with "…"
            CFRange r = CTLineGetStringRange(line);
            NSMutableAttributedString *rest = [[ct attributedSubstringFromRange:NSMakeRange((NSUInteger)r.location, ct.length - (NSUInteger)r.location)] mutableCopy];
            [[rest mutableString] replaceOccurrencesOfString:@"\n" withString:@" " options:0 range:NSMakeRange(0, rest.length)];
            NSUInteger last = (NSUInteger)r.location + (NSUInteger)MAX((CFIndex)0, r.length - 1);
            NSDictionary *tokenAttrs = [ct attributesAtIndex:MIN(last, ct.length - 1) effectiveRange:NULL];
            NSAttributedString *ellipsis = [[NSAttributedString alloc] initWithString:@"…" attributes:tokenAttrs];
            CTLineRef token = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)ellipsis);
            CTLineRef full = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)rest);
            CTLineRef cut = CTLineCreateTruncatedLine(full, width, kCTLineTruncationEnd, token);
            if (cut) {
                keep = (__bridge_transfer id)cut;
                offset = (NSUInteger)r.location;
                x = (CGFloat)CTLineGetPenOffsetForFlush((__bridge CTLineRef)keep, SHFlushFactor(alignment), width);
            }
            if (full) CFRelease(full);
            if (token) CFRelease(token);
        }
        CGFloat ascent = 0, descent = 0, leading = 0;
        double lineWidth = CTLineGetTypographicBounds((__bridge CTLineRef)keep, &ascent, &descent, &leading);
        lineWidth -= CTLineGetTrailingWhitespaceWidth((__bridge CTLineRef)keep);
        CGFloat baseline = tall - points[i].y;
        [lines addObject:keep];
        [origins addObject:[NSValue valueWithCGPoint:CGPointMake(x, baseline)]];
        [offsets addObject:@(offset)];
        [ascents addObject:@(ascent)];
        [descents addObject:@(descent)];
        widest = MAX(widest, (CGFloat)lineWidth);
        bottom = baseline + descent;
    }
    free(points);
    CFRelease(frame);
    CGPathRelease(path);
    CFRelease(setter);
    layout.size = CGSizeMake(ceilf(MIN(width, widest)), ceilf(bottom));
    return layout;
}

#pragma mark - Finding the links

static NSArray *SHFindLinks(NSString *s)
{
    if (!s.length) return @[];
    static NSRegularExpression *mention, *hashtag;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Instagram names: letters, digits, "_" and "." (never at the end), at most 30; not the middle of an e-mail address
        mention = [NSRegularExpression regularExpressionWithPattern:@"(?<![A-Za-z0-9_@.])@([A-Za-z0-9_](?:[A-Za-z0-9_.]{0,28}[A-Za-z0-9_])?)"
                                                            options:0 error:NULL];
        // tags of any script ("#léto"), at least one letter or "_" in them; not "&#39;"
        hashtag = [NSRegularExpression regularExpressionWithPattern:@"(?<![\\p{L}\\p{M}\\p{N}_&#])#([\\p{L}\\p{M}\\p{N}_]*[\\p{L}\\p{M}_][\\p{L}\\p{M}\\p{N}_]*)"
                                                            options:0 error:NULL];
    });
    NSMutableArray *links = [NSMutableArray array];
    for (NSTextCheckingResult *m in [SHUtils webLinksInText:s]) {
        if (!m.URL) continue;
        SHTextLink *l = [[SHTextLink alloc] init];
        l.kind = SHTextLinkWeb;
        l.range = m.range;
        l.value = m.URL.absoluteString;
        [links addObject:l];
    }
    NSArray *web = [links copy];
    void (^scan)(NSRegularExpression *, SHTextLinkKind) = ^(NSRegularExpression *re, SHTextLinkKind kind) {
        if (!re) return;
        [re enumerateMatchesInString:s options:0 range:NSMakeRange(0, s.length) usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
            for (SHTextLink *w in web) if (NSIntersectionRange(w.range, m.range).length) return;   // part of a web link
            SHTextLink *l = [[SHTextLink alloc] init];
            l.kind = kind;
            l.range = m.range;
            l.value = [[s substringWithRange:[m rangeAtIndex:1]] lowercaseString];
            [links addObject:l];
        }];
    };
    scan(mention, SHTextLinkMention);
    scan(hashtag, SHTextLinkHashtag);
    return links;
}

static CGFloat SHDistanceToRect(CGRect r, CGPoint p)
{
    CGFloat dx = MAX(0, MAX(CGRectGetMinX(r) - p.x, p.x - CGRectGetMaxX(r)));
    CGFloat dy = MAX(0, MAX(CGRectGetMinY(r) - p.y, p.y - CGRectGetMaxY(r)));
    return sqrtf((float)(dx * dx + dy * dy));
}

#pragma mark - The label

@interface SHLinkLabel () <UIGestureRecognizerDelegate>
@property (nonatomic, strong, readwrite) NSArray *links;
@property (nonatomic, strong) NSMutableArray *userLinks;
@property (nonatomic, strong) NSAttributedString *ct;
@property (nonatomic, strong) SHTextLayout *layout;
@property (nonatomic, strong) UITapGestureRecognizer *tap;
@property (nonatomic, strong) SHTextLink *highlighted;
@property (nonatomic) CGPoint lastPoint;   // where the last hit test asked (a synthetic tap of the test tools has no touch)
@end

@implementation SHLinkLabel

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
        self.isAccessibilityElement = YES;
        _font = [UIFont systemFontOfSize:14];
        _textColor = [[SHTheme shared] textColor];
        _linkColor = [[SHTheme shared] linkColor];
        _userLinks = [NSMutableArray array];
        _links = @[];
        _tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)];
        _tap.delegate = self;
        [self addGestureRecognizer:_tap];
    }
    return self;
}

- (void)rebuild
{
    NSAttributedString *source = _attributedText ?: [[NSAttributedString alloc] initWithString:_text ?: @""];
    NSMutableArray *links = [NSMutableArray array];
    for (SHTextLink *u in _userLinks) if (NSMaxRange(u.range) <= source.length) [links addObject:u];
    for (SHTextLink *l in SHFindLinks(source.string)) {
        BOOL clash = NO;
        for (SHTextLink *u in _userLinks) if (NSIntersectionRange(u.range, l.range).length) clash = YES;
        if (!clash) [links addObject:l];
    }
    [links sortUsingComparator:^NSComparisonResult(SHTextLink *a, SHTextLink *b) {
        return a.range.location < b.range.location ? NSOrderedAscending : a.range.location > b.range.location ? NSOrderedDescending : NSOrderedSame;
    }];
    _links = links;
    _ct = SHCoreTextString(source, _font, _textColor, _linkColor, links, _textAlignment);
    _layout = nil;
    _highlighted = nil;
    self.accessibilityLabel = source.string;
    self.accessibilityTraits = links.count ? (UIAccessibilityTraitStaticText | UIAccessibilityTraitLink) : UIAccessibilityTraitStaticText;
    [self setNeedsDisplay];
}

- (void)setText:(NSString *)text
{
    _text = [text copy];
    _attributedText = nil;
    [_userLinks removeAllObjects];
    [self rebuild];
}

- (void)setAttributedText:(NSAttributedString *)attributedText
{
    _attributedText = [attributedText copy];
    _text = attributedText.string;
    [_userLinks removeAllObjects];
    [self rebuild];
}

- (void)addUserLinkWithRange:(NSRange)range username:(NSString *)username pk:(NSString *)pk
{
    if (!username.length && !pk.length) return;
    SHTextLink *l = [[SHTextLink alloc] init];
    l.kind = SHTextLinkUser;
    l.range = range;
    l.value = username ?: @"";
    l.userPk = pk;
    [_userLinks addObject:l];
    [self rebuild];
}

- (void)setFont:(UIFont *)font { _font = font ?: [UIFont systemFontOfSize:14]; [self rebuild]; }
- (void)setTextColor:(UIColor *)textColor { _textColor = textColor; [self rebuild]; }
- (void)setLinkColor:(UIColor *)linkColor { _linkColor = linkColor; [self rebuild]; }
- (void)setTextAlignment:(UITextAlignment)textAlignment { _textAlignment = textAlignment; [self rebuild]; }
- (void)setShadowColor:(UIColor *)shadowColor { _shadowColor = shadowColor; [self setNeedsDisplay]; }
- (void)setShadowOffset:(CGSize)shadowOffset { _shadowOffset = shadowOffset; [self setNeedsDisplay]; }
- (void)setNumberOfLines:(NSInteger)numberOfLines { _numberOfLines = numberOfLines; _layout = nil; [self setNeedsDisplay]; }

- (SHTextLayout *)currentLayout
{
    CGFloat w = self.bounds.size.width;
    if (!_layout || fabs(_layout.width - w) > 0.5 || _layout.maxLines != _numberOfLines)
        _layout = SHLayoutText(_ct, w, _numberOfLines, _textAlignment);
    return _layout;
}

- (CGSize)sizeThatFits:(CGSize)size
{
    return SHLayoutText(_ct, size.width > 0 ? size.width : self.bounds.size.width, _numberOfLines, _textAlignment).size;
}

#pragma mark - Measuring

static NSString *SHMeasureKey(NSAttributedString *text, CGFloat width, NSInteger lines)
{
    NSMutableString *key = [NSMutableString stringWithFormat:@"%.1f|%ld|", width, (long)lines];
    [text enumerateAttribute:SHTextFontAttributeName inRange:NSMakeRange(0, text.length) options:0 usingBlock:^(id value, NSRange range, BOOL *stop) {
        UIFont *f = [value isKindOfClass:[UIFont class]] ? value : nil;
        [key appendFormat:@"%@%.1f@%lu+%lu,", f.fontName ?: @"-", f ? f.pointSize : 0, (unsigned long)range.location, (unsigned long)range.length];
    }];
    [key appendString:text.string];
    return key;
}

+ (CGSize)sizeForAttributedText:(NSAttributedString *)text width:(CGFloat)width lines:(NSInteger)lines
{
    if (!text.length || width <= 1) return CGSizeZero;
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; cache.countLimit = 800; });
    NSString *key = SHMeasureKey(text, width, lines);
    NSValue *known = [cache objectForKey:key];
    if (known) return [known CGSizeValue];
    NSAttributedString *ct = SHCoreTextString(text, [UIFont systemFontOfSize:14], [UIColor blackColor], nil, nil, UITextAlignmentLeft);
    CGSize size = SHLayoutText(ct, width, lines, UITextAlignmentLeft).size;
    [cache setObject:[NSValue valueWithCGSize:size] forKey:key];
    return size;
}

+ (CGSize)sizeForText:(NSString *)text font:(UIFont *)font width:(CGFloat)width lines:(NSInteger)lines
{
    if (!text.length) return CGSizeZero;
    NSAttributedString *a = [[NSAttributedString alloc] initWithString:text attributes:@{ SHTextFontAttributeName: font ?: [UIFont systemFontOfSize:14] }];
    return [self sizeForAttributedText:a width:width lines:lines];
}

#pragma mark - Drawing

// Where a stretch of the text lies, one rectangle per line it is on.
- (NSArray *)rectsForRange:(NSRange)range
{
    SHTextLayout *layout = [self currentLayout];
    NSMutableArray *rects = [NSMutableArray array];
    for (NSUInteger i = 0; i < layout.lines.count; i++) {
        CTLineRef line = (__bridge CTLineRef)[layout.lines objectAtIndex:i];
        NSUInteger offset = [[layout.offsets objectAtIndex:i] unsignedIntegerValue];
        CFRange lr = CTLineGetStringRange(line);
        NSRange lineRange = NSMakeRange((NSUInteger)lr.location + offset, (NSUInteger)lr.length);
        NSRange common = NSIntersectionRange(lineRange, range);
        if (!common.length) continue;
        CGFloat x0 = CTLineGetOffsetForStringIndex(line, (CFIndex)(common.location - offset), NULL);
        CGFloat x1 = CTLineGetOffsetForStringIndex(line, (CFIndex)(NSMaxRange(common) - offset), NULL);
        CGPoint o = [[layout.origins objectAtIndex:i] CGPointValue];
        CGFloat ascent = [[layout.ascents objectAtIndex:i] floatValue], descent = [[layout.descents objectAtIndex:i] floatValue];
        [rects addObject:[NSValue valueWithCGRect:CGRectMake(o.x + MIN(x0, x1), o.y - ascent, (CGFloat)fabs(x1 - x0), ascent + descent)]];
    }
    return rects;
}

- (SHTextLink *)linkAtPoint:(CGPoint)p
{
    SHTextLink *best = nil;
    CGFloat bestDistance = 9;   // a fingertip's slack around the words
    for (SHTextLink *l in _links) {
        for (NSValue *v in [self rectsForRange:l.range]) {
            CGFloat d = SHDistanceToRect([v CGRectValue], p);
            if (d < bestDistance) { bestDistance = d; best = l; }
        }
    }
    return best;
}

- (void)drawRect:(CGRect)rect
{
    SHTextLayout *layout = [self currentLayout];
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (_highlighted) {
        // the touched link sits in a soft rounded box until the finger lifts, as links did in iOS 6
        [[(_linkColor ?: [UIColor grayColor]) colorWithAlphaComponent:0.22f] setFill];
        for (NSValue *v in [self rectsForRange:_highlighted.range])
            [[UIBezierPath bezierPathWithRoundedRect:CGRectInset([v CGRectValue], -2, -1) cornerRadius:3] fill];
    }
    CGContextSaveGState(ctx);
    CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
    CGFloat h = self.bounds.size.height;
    CGContextTranslateCTM(ctx, 0, h);
    CGContextScaleCTM(ctx, 1, -1);
    if (_shadowColor) CGContextSetShadowWithColor(ctx, _shadowOffset, 0, _shadowColor.CGColor);   // (offsets are not flipped)
    for (NSUInteger i = 0; i < layout.lines.count; i++) {
        CGPoint o = [[layout.origins objectAtIndex:i] CGPointValue];
        CGContextSetTextPosition(ctx, o.x, h - o.y);
        CTLineDraw((__bridge CTLineRef)[layout.lines objectAtIndex:i], ctx);
    }
    CGContextRestoreGState(ctx);
}

#pragma mark - Touches

// The label takes a touch only on a link (or anywhere, with textTapHandler); the rest goes to what lies under it.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event
{
    if (!CGRectContainsPoint(CGRectInset(self.bounds, -4, -4), point)) return NO;
    _lastPoint = point;
    if (_textTapHandler) return YES;
    return [self linkAtPoint:point] != nil;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g
{
    if (g == _tap) return YES;
    // a tap recognizer of a view around the label (a bubble, a page) stays out of a tap on a link
    if ([g isKindOfClass:[UITapGestureRecognizer class]] && [self linkAtPoint:[g locationInView:self]]) return NO;
    return [super gestureRecognizerShouldBegin:g];
}

- (void)setHighlightedLink:(SHTextLink *)link
{
    if (_highlighted == link) return;
    _highlighted = link;
    [self setNeedsDisplay];
}

// (the touches stop here: a tap on a link is not also a tap on the row or the bubble under it)
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
    [self setHighlightedLink:[self linkAtPoint:[[touches anyObject] locationInView:self]]];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {}
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event { [self clearHighlightSoon]; }
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event { [self clearHighlightSoon]; }

- (void)clearHighlightSoon
{
    __weak SHLinkLabel *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf setHighlightedLink:nil];
    });
}

- (void)tapped:(UITapGestureRecognizer *)g
{
    CGPoint p = g.state == UIGestureRecognizerStateEnded ? [g locationInView:self] : _lastPoint;
    SHTextLink *link = [self linkAtPoint:p];
    if (link) {
        [self setHighlightedLink:link];
        [self clearHighlightSoon];
        if (_linkHandler) _linkHandler(link);
        else [SHLinkLabel openLink:link from:self];
        return;
    }
    if (_textTapHandler) _textTapHandler();
}

#pragma mark - Opening

+ (UIViewController *)controllerOfView:(UIView *)view
{
    UIResponder *r = view.nextResponder;
    while (r && ![r isKindOfClass:[UIViewController class]]) r = r.nextResponder;
    return (UIViewController *)r;
}

+ (void)openLink:(SHTextLink *)link from:(UIView *)view
{
    switch (link.kind) {
        case SHTextLinkMention:
        case SHTextLinkUser:
            [SHLinkRouter openProfileWithUsername:link.value pk:link.userPk];
            break;
        case SHTextLinkHashtag:
            [SHLinkRouter openHashtag:link.value];
            break;
        case SHTextLinkWeb:
            [SHLinkRouter openWebLink:link.value from:[self controllerOfView:view] anchor:view];
            break;
    }
}

@end
