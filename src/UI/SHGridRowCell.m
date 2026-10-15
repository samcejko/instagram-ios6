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
        self.backgroundColor = [[SHTheme shared] backgroundColor];
        self.contentView.backgroundColor = [[SHTheme shared] backgroundColor];
        _thumbs = [NSMutableArray array];
        for (NSUInteger i = 0; i < SH_GRID_COLS; i++) {
            SHGridThumb *t = [[SHGridThumb alloc] initWithFrame:CGRectZero];
            t.contentMode = UIViewContentModeScaleAspectFill;
            t.clipsToBounds = YES;
            t.backgroundColor = [[SHTheme shared] separatorColor];
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
        SHGridThumb *t = _thumbs[i];
        t.frame = CGRectMake((cell + SH_GRID_GAP) * (CGFloat)i, 0, cell, cell);
    }
}

- (void)configureWithPosts:(NSArray *)posts
{
    for (NSUInteger i = 0; i < SH_GRID_COLS; i++) {
        SHGridThumb *t = _thumbs[i];
        if (i < posts.count) {
            SHPost *p = posts[i];
            t.post = p;
            t.hidden = NO;
            [t setImageURL:p.image.url placeholder:nil];
            [self markThumb:t forPost:p];
        } else {
            t.post = nil;
            t.hidden = YES;
            [t setImageURL:nil placeholder:nil];
        }
    }
}

- (void)markThumb:(SHGridThumb *)t forPost:(SHPost *)p
{
    [t.badge removeFromSuperview];
    t.badge = nil;
    NSString *glyph = nil;
    if (p.carouselMedia.count > 1) glyph = @"▣";        // stacked squares-ish
    else if (p.mediaType == 2 || p.videoURL.length) glyph = @"▶";   // play
    if (!glyph) return;
    UILabel *mark = [[UILabel alloc] initWithFrame:CGRectMake(0, 2, 20, 16)];
    mark.text = glyph;
    mark.font = [UIFont boldSystemFontOfSize:12];
    mark.textColor = [UIColor whiteColor];
    mark.backgroundColor = [UIColor clearColor];
    mark.shadowColor = [UIColor colorWithWhite:0 alpha:0.6];
    mark.shadowOffset = CGSizeMake(0, 0.5);
    mark.textAlignment = NSTextAlignmentRight;
    mark.frame = CGRectMake(t.bounds.size.width - 24, 2, 20, 16);
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
