#import "SHStoryBarView.h"
#import "SHModels.h"
#import "SHImageLoader.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHCommon.h"

static const CGFloat SHStorySize = 56;   // the picture; the glossy ring goes around it
static const CGFloat SHStoryPad = 10;

@interface SHStoryBarView ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) NSArray *reels;
@end

@implementation SHStoryBarView

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        SHTheme *theme = [SHTheme shared];
        // a shelf on the linen: the circles sit on it, an etched groove under it
        UIView *shelf = [theme texturedBackgroundView];
        shelf.frame = self.bounds;
        [self addSubview:shelf];

        _scrollView = [[UIScrollView alloc] initWithFrame:self.bounds];
        _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _scrollView.showsHorizontalScrollIndicator = NO;
        _scrollView.alwaysBounceHorizontal = YES;
        _scrollView.backgroundColor = [UIColor clearColor];
        [self addSubview:_scrollView];

        UIView *dark = [[UIView alloc] initWithFrame:CGRectMake(0, frame.size.height - 2, frame.size.width, 1)];
        dark.backgroundColor = [UIColor colorWithWhite:0 alpha:theme.isDark ? 0.8 : 0.2];
        dark.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        [self addSubview:dark];
        UIView *light = [[UIView alloc] initWithFrame:CGRectMake(0, frame.size.height - 1, frame.size.width, 1)];
        light.backgroundColor = [UIColor colorWithWhite:1 alpha:theme.isDark ? 0.07 : 0.8];
        light.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        [self addSubview:light];
    }
    return self;
}

- (void)setReels:(NSArray *)reels
{
    _reels = reels;
    SHTheme *theme = [SHTheme shared];
    for (UIView *v in [_scrollView.subviews copy]) [v removeFromSuperview];
    CGFloat ringSize = SHStorySize + 10;
    CGFloat x = SHStoryPad;
    for (NSUInteger i = 0; i < reels.count; i++) {
        SHStoryReel *reel = reels[i];
        UIView *container = [[UIView alloc] initWithFrame:CGRectMake(x, 5, ringSize, self.bounds.size.height - 8)];
        container.tag = (NSInteger)i;

        // a highlight: its cover in a grey ring and its name under it (stories: the person, coloured until seen)
        BOOL highlight = reel.isHighlight;
        UIImageView *ring = [[UIImageView alloc] initWithImage:[theme storyRingImageWithSize:ringSize seen:highlight || reel.seen]];
        ring.frame = CGRectMake(0, 0, ringSize, ringSize);
        [container addSubview:ring];

        SHImageView *avatar = [[SHImageView alloc] initWithFrame:CGRectMake(5, 5, SHStorySize, SHStorySize)];
        [theme styleAvatar:avatar radius:SHStorySize / 2];
        avatar.maxPixels = 160;
        [avatar setImageURL:highlight && reel.coverURL.length ? reel.coverURL : reel.user.profilePicURL
                placeholder:[theme avatarPlaceholderWithSize:SHStorySize]];
        [container addSubview:avatar];

        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(-6, ringSize + 2, ringSize + 12, 14)];
        name.text = highlight ? [SHUtils displayText:reel.title ?: @""] : reel.user.username;
        name.font = [UIFont boldSystemFontOfSize:10];
        name.textColor = reel.seen && !highlight ? [theme secondaryTextColor] : [theme textColor];
        name.backgroundColor = [UIColor clearColor];
        name.textAlignment = NSTextAlignmentCenter;
        name.lineBreakMode = NSLineBreakByTruncatingTail;
        [theme embossLabel:name];
        [container addSubview:name];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(reelTapped:)];
        [container addGestureRecognizer:tap];
        [_scrollView addSubview:container];
        x += ringSize + SHStoryPad;
    }
    _scrollView.contentSize = CGSizeMake(x, self.bounds.size.height);
}

- (void)reelTapped:(UITapGestureRecognizer *)gesture
{
    NSUInteger idx = (NSUInteger)gesture.view.tag;
    if (idx < _reels.count && [_delegate respondsToSelector:@selector(storyBar:didSelectReel:atIndex:)])
        [_delegate storyBar:self didSelectReel:_reels[idx] atIndex:idx];
}

@end
