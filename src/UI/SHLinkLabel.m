#import "SHLinkLabel.h"
#import "SHLinkRouter.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHCommon.h"

@interface SHLinkLabel ()
@property (nonatomic, strong) NSArray *links;
@property (nonatomic, strong) NSArray *linkRanges;         // NSValue (NSRange), one per link
@property (nonatomic) NSLineBreakMode wantedLineBreakMode;  // the label's own (an attributed text leaves word wrapping behind)
@property (nonatomic) BOOL applying;                       // (UILabel sets its style properties back while an attributed text is set)
@end

@implementation SHLinkLabel

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        _linkColor = [[SHTheme shared] linkColor];
        _links = @[];
        _linkRanges = @[];
        _wantedLineBreakMode = self.lineBreakMode;
        self.userInteractionEnabled = NO;
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)]];
    }
    return self;
}

- (void)setText:(NSString *)text
{
    if (self.applying) { [super setText:text]; return; }
    NSMutableArray *links = [NSMutableArray array], *ranges = [NSMutableArray array];
    for (NSTextCheckingResult *m in [SHUtils webLinksInText:text ?: @""]) {
        [links addObject:m.URL];
        [ranges addObject:[NSValue valueWithRange:m.range]];
    }
    self.links = links;
    self.linkRanges = ranges;
    self.userInteractionEnabled = links.count > 0;
    self.accessibilityTraits = links.count ? (UIAccessibilityTraitStaticText | UIAccessibilityTraitLink) : UIAccessibilityTraitStaticText;
    [super setLineBreakMode:self.wantedLineBreakMode];
    [super setText:text];       // (the plain text: the label's own font, colour and shadow)
    [self applyLinks];
}

// The style properties feed the text with the links; changed afterwards, they are applied again
- (void)setFont:(UIFont *)font { [super setFont:font]; if (!self.applying) [self applyLinks]; }
- (void)setTextColor:(UIColor *)color { [super setTextColor:color]; if (!self.applying) [self applyLinks]; }
- (void)setShadowColor:(UIColor *)color { [super setShadowColor:color]; if (!self.applying) [self applyLinks]; }
- (void)setShadowOffset:(CGSize)offset { [super setShadowOffset:offset]; if (!self.applying) [self applyLinks]; }
- (void)setTextAlignment:(NSTextAlignment)alignment { [super setTextAlignment:alignment]; if (!self.applying) [self applyLinks]; }
- (void)setLineBreakMode:(NSLineBreakMode)mode { if (!self.applying) _wantedLineBreakMode = mode; [super setLineBreakMode:mode]; }
- (void)setLinkColor:(UIColor *)color { _linkColor = color; [self applyLinks]; }

// The text with its links in the link colour. The font is the same everywhere, so the label measures as the plain
// text does. The lines wrap by words: a truncating mode inside an attributed text makes a label show one line only,
// so a text with links that runs past numberOfLines ends without the "…".
- (void)applyLinks
{
    NSString *s = self.text;
    if (!self.linkRanges.count || !s.length || !self.font) return;
    NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:s];
    NSRange all = NSMakeRange(0, s.length);
    [a addAttribute:NSFontAttributeName value:self.font range:all];
    [a addAttribute:NSForegroundColorAttributeName value:self.textColor ?: [UIColor blackColor] range:all];
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = self.textAlignment;
    paragraph.lineBreakMode = NSLineBreakByWordWrapping;
    [a addAttribute:NSParagraphStyleAttributeName value:paragraph range:all];
    if (self.shadowColor) {
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowColor = self.shadowColor;
        shadow.shadowOffset = self.shadowOffset;
        [a addAttribute:NSShadowAttributeName value:shadow range:all];
    }
    UIColor *link = self.linkColor ?: [[SHTheme shared] linkColor];
    for (NSValue *v in self.linkRanges) {
        NSRange r = v.rangeValue;
        if (NSMaxRange(r) <= s.length) [a addAttribute:NSForegroundColorAttributeName value:link range:r];
    }
    self.applying = YES;
    [super setAttributedText:a];
    self.applying = NO;
}

// The screen the label is on (for the sheets)
- (UIViewController *)owningController
{
    UIResponder *r = self.nextResponder;
    while (r && ![r isKindOfClass:[UIViewController class]]) r = r.nextResponder;
    return (UIViewController *)r;
}

- (void)tapped:(UITapGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateEnded || !self.links.count) return;
    [SHLinkRouter openWebLinks:self.links from:[self owningController] anchor:self];
}

@end
