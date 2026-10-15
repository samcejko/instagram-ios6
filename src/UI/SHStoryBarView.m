#import "SHStoryBarView.h"
#import "SHModels.h"
#import "SHImageLoader.h"
#import "SHTheme.h"
#import "SHCommon.h"

static const CGFloat SHStorySize = 56;
static const CGFloat SHStoryPad = 8;

@interface SHStoryBarView ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) NSArray *reels;
@end

@implementation SHStoryBarView

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [[SHTheme shared] backgroundColor];
        _scrollView = [[UIScrollView alloc] initWithFrame:self.bounds];
        _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _scrollView.showsHorizontalScrollIndicator = NO;
        _scrollView.alwaysBounceHorizontal = YES;
        [self addSubview:_scrollView];

        UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, frame.size.height - 0.5, frame.size.width, 0.5)];
        sep.backgroundColor = [[SHTheme shared] separatorColor];
        sep.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        [self addSubview:sep];
    }
    return self;
}

- (void)setReels:(NSArray *)reels
{
    _reels = reels;
    for (UIView *v in [_scrollView.subviews copy]) [v removeFromSuperview];
    CGFloat x = SHStoryPad;
    for (NSUInteger i = 0; i < reels.count; i++) {
        SHStoryReel *reel = reels[i];
        UIView *container = [[UIView alloc] initWithFrame:CGRectMake(x, 4, SHStorySize + 8, self.bounds.size.height - 8)];
        container.tag = (NSInteger)i;

        UIView *ring = [[UIView alloc] initWithFrame:CGRectMake(0, 0, SHStorySize + 8, SHStorySize + 8)];
        ring.layer.cornerRadius = (SHStorySize + 8) / 2;
        ring.layer.borderWidth = reel.seen ? 1 : 2;
        ring.layer.borderColor = reel.seen ? [[SHTheme shared] separatorColor].CGColor : [UIColor colorWithRed:0.83 green:0.18 blue:0.35 alpha:1].CGColor;
        [container addSubview:ring];

        SHImageView *avatar = [[SHImageView alloc] initWithFrame:CGRectMake(4, 4, SHStorySize, SHStorySize)];
        avatar.layer.cornerRadius = SHStorySize / 2;
        avatar.clipsToBounds = YES;
        avatar.backgroundColor = [[SHTheme shared] separatorColor];
        [avatar setImageURL:reel.user.profilePicURL placeholder:nil];
        [container addSubview:avatar];

        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(-4, SHStorySize + 10, SHStorySize + 16, 14)];
        name.text = reel.user.username;
        name.font = [UIFont systemFontOfSize:10];
        name.textColor = [[SHTheme shared] textColor];
        name.backgroundColor = [UIColor clearColor];
        name.textAlignment = NSTextAlignmentCenter;
        name.lineBreakMode = NSLineBreakByTruncatingTail;
        [container addSubview:name];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(reelTapped:)];
        [container addGestureRecognizer:tap];
        [_scrollView addSubview:container];
        x += SHStorySize + SHStoryPad + 8;
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
