#import "SHGridRowCell.h"
#import "SHImageLoader.h"
#import "SHModels.h"
#import "SHTheme.h"
#import "SHCommon.h"

#define SH_GRID_COLS 3
#define SH_GRID_GAP 1.0

@interface SHGridThumb : SHImageView
@property (nonatomic, strong) SHPost *post;
@property (nonatomic, strong) UIView *badge;   // a small corner mark for video / carousel
@end
@implementation SHGridThumb
@end

@implementation SHGridRowCell {
    NSMutableArray *_thumbs;   // SHGridThumb
}

+ (NSUInteger)columns { return SH_GRID_COLS; }

+ (CGFloat)rowHeightForWidth:(CGFloat)width
{
    CGFloat cell = floorf((width - SH_GRID_GAP * (SH_GRID_COLS - 1)) / SH_GRID_COLS);
    return cell + SH_GRID_GAP;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];          // the linen shows in the gaps
        self.contentView.backgroundColor = [UIColor clearColor];
        _thumbs = [NSMutableArray array];
        for (NSUInteger i = 0; i < SH_GRID_COLS; i++) {
            SHGridThumb *t = [[SHGridThumb alloc] initWithFrame:CGRectZero];
            t.contentMode = UIViewContentModeScaleAspectFill;
            t.clipsToBounds = YES;
            t.backgroundColor = [[SHTheme shared] isDark] ? [UIColor colorWithWhite:0.14 alpha:1] : [UIColor colorWithWhite:0.82 alpha:1];
            t.userInteractionEnabled = YES;
            t.maxPixels = 400;
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(thumbTapped:)];
            [t addGestureRecognizer:tap];
            [self.contentView addSubview:t];
            [_thumbs addObject:t];
        }
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat cell = floorf((w - SH_GRID_GAP * (SH_GRID_COLS - 1)) / SH_GRID_COLS);
    for (NSUInteger i = 0; i < SH_GRID_COLS; i++) {
        SHGridThumb *t = [_thumbs objectAtIndex:i];
        t.frame = CGRectMake((cell + SH_GRID_GAP) * (CGFloat)i, 0, cell, cell);
    }
}

- (void)configureWithPosts:(NSArray *)posts
{
    for (NSUInteger i = 0; i < SH_GRID_COLS; i++) {
        SHGridThumb *t = [_thumbs objectAtIndex:i];
        if (i < posts.count) {
            SHPost *p = [posts objectAtIndex:i];
            t.post = p;
            t.hidden = NO;
            t.maxPixels = 320;
            [t setImageURL:p.thumbImage.url ?: p.image.url placeholder:nil];
            [self markThumb:t forPost:p];
        } else {
            t.post = nil;
            t.hidden = YES;
            [t setImageURL:nil placeholder:nil];
        }
    }
}

// A drawn corner mark (white with a soft shadow, never an emoji): stacked squares for a carousel, a movie camera
// for a video.
- (void)markThumb:(SHGridThumb *)t forPost:(SHPost *)p
{
    [t.badge removeFromSuperview];
    t.badge = nil;
    UIImage *glyph = nil;
    if (p.carouselMedia.count > 1) glyph = [[SHTheme shared] carouselGlyph];
    else if (p.mediaType == 2 || p.videoURL.length) glyph = [[SHTheme shared] videoGlyph];
    if (!glyph) return;
    UIImageView *mark = [[UIImageView alloc] initWithImage:glyph];
    mark.frame = CGRectMake(t.bounds.size.width - glyph.size.width - 5, 5, glyph.size.width, glyph.size.height);
    mark.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [t addSubview:mark];
    t.badge = mark;
}

- (void)thumbTapped:(UITapGestureRecognizer *)g
{
    SHGridThumb *t = (SHGridThumb *)g.view;
    if (t.post && [self.delegate respondsToSelector:@selector(gridRow:didTapPost:)])
        [self.delegate gridRow:self didTapPost:t.post];
}

@end
