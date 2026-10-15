#import "SHPostDetailViewController.h"
#import "SHTabIcons.h"
#import "SHCommentsViewController.h"
#import "SHProfileViewController.h"
#import "SHUserListViewController.h"
#import "SHInstagram.h"
#import "SHModels.h"
#import "SHImageLoader.h"
#import "SHMediaProxy.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHLinkRouter.h"
#import "SHCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>

static const CGFloat SHDetailHeaderH = 50;

@interface SHPostDetailViewController () <UIScrollViewDelegate>
@property (nonatomic, strong) SHPost *post;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIScrollView *carousel;     // horizontal pager for multi-image posts
@property (nonatomic, strong) UIPageControl *pageControl;
@property (nonatomic, strong) UILabel *likesLabel;
@property (nonatomic, strong) UIButton *likeButton;
@property (nonatomic, strong) UIButton *saveButton;
@property (nonatomic, strong) MPMoviePlayerController *player;
@end

@implementation SHPostDetailViewController

- (instancetype)initWithPost:(SHPost *)post
{
    if ((self = [super init])) _post = post;
    return self;
}

- (NSArray *)mediaItems
{
    if (_post.carouselMedia.count > 1) return _post.carouselMedia;
    return _post ? @[ _post ] : @[];
}

- (UIButton *)glossyButton:(NSString *)title image:(UIImage *)image action:(SEL)action
{
    SHTheme *theme = [SHTheme shared];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setBackgroundImage:[theme buttonImageHighlighted:NO] forState:UIControlStateNormal];
    [b setBackgroundImage:[theme buttonImageHighlighted:YES] forState:UIControlStateHighlighted];
    if (image) [b setImage:image forState:UIControlStateNormal];
    if (title) {
        [b setTitle:title forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        [b setTitleColor:[theme textColor] forState:UIControlStateNormal];
        b.titleEdgeInsets = UIEdgeInsetsMake(0, 6, 0, 0);
        [theme embossButton:b];
    }
    b.adjustsImageWhenHighlighted = NO;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    SHTheme *theme = [SHTheme shared];
    self.title = _post.user.username.length ? _post.user.username : L(@"Post");
    self.view.backgroundColor = [theme linenColor];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:L(@"Comments")
        style:UIBarButtonItemStyleBordered target:self action:@selector(commentsTapped)];

    CGFloat w = self.view.bounds.size.width;
    _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scrollView.indicatorStyle = theme.isDark ? UIScrollViewIndicatorStyleWhite : UIScrollViewIndicatorStyleDefault;
    [self.view addSubview:_scrollView];

    // the glossy header: picture, name (both open the profile), the time with a clock
    UIImageView *header = [[UIImageView alloc] initWithImage:[theme headerBarImage]];
    header.frame = CGRectMake(0, 0, w, SHDetailHeaderH);
    header.userInteractionEnabled = YES;
    [header addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(userTapped)]];
    SHImageView *avatar = [[SHImageView alloc] initWithFrame:CGRectMake(10, 8, 34, 34)];
    [theme styleAvatar:avatar radius:4];
    avatar.maxPixels = 96;
    [avatar setImageURL:_post.user.profilePicURL placeholder:[theme avatarPlaceholderWithSize:34]];
    [header addSubview:avatar];
    UILabel *time = [[UILabel alloc] init];
    time.text = _post.takenAt ? [SHUtils formatRelativeDate:_post.takenAt] : @"";
    time.font = [UIFont boldSystemFontOfSize:11];
    time.textColor = [theme secondaryTextColor];
    time.backgroundColor = [UIColor clearColor];
    [theme embossLabel:time];
    CGFloat timeW = [time.text sizeWithFont:time.font].width;
    time.frame = CGRectMake(w - 10 - timeW, 0, timeW, SHDetailHeaderH);
    [header addSubview:time];
    UIImageView *clock = [[UIImageView alloc] initWithImage:[theme clockGlyph]];
    clock.frame = CGRectMake(time.frame.origin.x - 16, floorf((SHDetailHeaderH - 12) / 2), 12, 12);
    [header addSubview:clock];
    UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(54, 0, clock.frame.origin.x - 62, SHDetailHeaderH)];
    name.text = _post.user.username;
    name.font = [UIFont boldSystemFontOfSize:14];
    name.textColor = [theme textColor];
    name.backgroundColor = [UIColor clearColor];
    [theme embossLabel:name];
    [header addSubview:name];
    [_scrollView addSubview:header];

    CGFloat top = SHDetailHeaderH;
    CGFloat imgH = w;
    if (_post.image && _post.image.width > 0 && _post.image.height > 0) {
        imgH = w * ((CGFloat)_post.image.height / (CGFloat)_post.image.width);
        if (imgH > w * 1.5) imgH = w * 1.5;
        if (imgH < w * 0.6) imgH = w * 0.6;
    }
    imgH = floorf(imgH);

    NSArray *items = [self mediaItems];
    BOOL isVideo = _post.carouselMedia.count <= 1 && _post.videoURL.length > 0;
    UIColor *mediaBack = theme.isDark ? [UIColor colorWithWhite:0.1 alpha:1] : [UIColor colorWithWhite:0.85 alpha:1];

    if (isVideo) {
        SHImageView *poster = [[SHImageView alloc] initWithFrame:CGRectMake(0, top, w, imgH)];
        poster.contentMode = UIViewContentModeScaleAspectFill;
        poster.clipsToBounds = YES;
        poster.backgroundColor = mediaBack;
        poster.maxPixels = 1024;
        [poster setImageURL:_post.image.url placeholder:nil];
        [_scrollView addSubview:poster];
        NSString *proxied = [[SHMediaProxy shared] proxyURLForURL:[NSURL URLWithString:_post.videoURL]];
        _player = [[MPMoviePlayerController alloc] initWithContentURL:[NSURL URLWithString:proxied]];
        _player.view.frame = CGRectMake(0, top, w, imgH);
        _player.view.backgroundColor = [UIColor clearColor];
        _player.backgroundView.backgroundColor = [UIColor clearColor];   // the poster shows until it plays
        _player.controlStyle = MPMovieControlStyleEmbedded;
        _player.shouldAutoplay = NO;
        [_scrollView addSubview:_player.view];
        // a glossy play button over the poster starts it
        UIButton *play = [UIButton buttonWithType:UIButtonTypeCustom];
        [play setImage:[theme playButtonImageWithSize:72] forState:UIControlStateNormal];
        play.frame = CGRectMake(floorf((w - 72) / 2), top + floorf((imgH - 72) / 2), 72, 72);
        [play addTarget:self action:@selector(playTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_scrollView addSubview:play];
    } else {
        _carousel = [[UIScrollView alloc] initWithFrame:CGRectMake(0, top, w, imgH)];
        _carousel.pagingEnabled = YES;
        _carousel.showsHorizontalScrollIndicator = NO;
        _carousel.delegate = self;
        _carousel.contentSize = CGSizeMake(w * items.count, imgH);
        for (NSUInteger i = 0; i < items.count; i++) {
            SHPost *item = items[i];
            SHImageView *iv = [[SHImageView alloc] initWithFrame:CGRectMake(w * (CGFloat)i, 0, w, imgH)];
            iv.contentMode = UIViewContentModeScaleAspectFill;
            iv.clipsToBounds = YES;
            iv.backgroundColor = mediaBack;
            iv.maxPixels = 1024;
            iv.userInteractionEnabled = YES;
            UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(photoDoubleTapped)];
            doubleTap.numberOfTapsRequired = 2;
            [iv addGestureRecognizer:doubleTap];
            [iv setImageURL:item.image.url placeholder:nil];
            [_carousel addSubview:iv];
        }
        [_scrollView addSubview:_carousel];
        if (items.count > 1) {
            _pageControl = [[UIPageControl alloc] initWithFrame:CGRectMake(0, top + imgH - 24, w, 16)];
            _pageControl.numberOfPages = (NSInteger)items.count;
            _pageControl.userInteractionEnabled = NO;
            [_scrollView addSubview:_pageControl];
        }
    }

    CGFloat y = top + imgH + 8;

    // glossy Like / Comment buttons and the bookmark, as in the app of the iOS 6 days
    _likeButton = [self glossyButton:L(@"Like") image:nil action:@selector(likeTapped)];
    CGFloat likeW = MAX(110, [L(@"Like") sizeWithFont:[UIFont boldSystemFontOfSize:13]].width + 50);
    _likeButton.frame = CGRectMake(10, y, likeW, 32);
    [_scrollView addSubview:_likeButton];

    UIButton *commentButton = [self glossyButton:L(@"Comment") image:[SHTabIcons commentBubbleWithSize:17 color:[theme textColor] dark:theme.isDark]
                                          action:@selector(commentsTapped)];
    CGFloat commentW = MAX(110, [L(@"Comment") sizeWithFont:[UIFont boldSystemFontOfSize:13]].width + 50);
    commentButton.frame = CGRectMake(10 + likeW + 8, y, commentW, 32);
    [_scrollView addSubview:commentButton];

    _saveButton = [self glossyButton:nil image:nil action:@selector(saveTapped)];
    _saveButton.frame = CGRectMake(w - 52, y, 42, 32);
    [_scrollView addSubview:_saveButton];
    y += 32 + 10;

    UIImageView *heart = [[UIImageView alloc] initWithImage:[SHTabIcons heartWithSize:14 filled:YES color:[theme linkColor] dark:theme.isDark]];
    heart.frame = CGRectMake(12, y + 3, heart.image.size.width, heart.image.size.height);
    [_scrollView addSubview:heart];
    _likesLabel = [[UILabel alloc] initWithFrame:CGRectMake(32, y, w - 44, 20)];
    _likesLabel.font = [UIFont boldSystemFontOfSize:14];
    _likesLabel.textColor = [theme linkColor];
    _likesLabel.backgroundColor = [UIColor clearColor];
    [theme embossLabel:_likesLabel];
    _likesLabel.userInteractionEnabled = YES;
    [_likesLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showLikers)]];
    [_scrollView addSubview:_likesLabel];
    [self updateLikeUI];
    [self updateSaveUI];
    y += 26;

    if (_post.captionText.length) {
        UILabel *caption = [[UILabel alloc] initWithFrame:CGRectMake(12, y, w - 24, 0)];
        caption.numberOfLines = 0;
        caption.backgroundColor = [UIColor clearColor];
        caption.shadowColor = theme.isDark ? [UIColor colorWithWhite:0 alpha:0.8] : [UIColor colorWithWhite:1 alpha:0.9];
        caption.shadowOffset = theme.isDark ? CGSizeMake(0, -1) : CGSizeMake(0, 1);
        NSString *user = _post.user.username ?: @"";
        NSString *text = [NSString stringWithFormat:@"%@ %@", user, [SHUtils displayText:_post.captionText]];
        NSMutableAttributedString *cap = [[NSMutableAttributedString alloc] initWithString:text attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:14], NSForegroundColorAttributeName: [theme textColor] }];
        [cap addAttributes:@{ NSFontAttributeName: [UIFont boldSystemFontOfSize:14], NSForegroundColorAttributeName: [theme linkColor] }
                     range:NSMakeRange(0, MIN(user.length, text.length))];
        caption.attributedText = cap;
        CGSize sz = [caption sizeThatFits:CGSizeMake(w - 24, 9999)];
        caption.frame = CGRectMake(12, y, w - 24, sz.height);
        [_scrollView addSubview:caption];
        y += sz.height + 12;
    }

    _scrollView.contentSize = CGSizeMake(w, y + 20);
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    if (scrollView == _carousel && _pageControl)
        _pageControl.currentPage = (NSInteger)(scrollView.contentOffset.x / scrollView.bounds.size.width + 0.5);
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [_player stop];
}

- (void)playTapped:(UIButton *)button
{
    button.hidden = YES;
    [_player play];
}

- (void)userTapped
{
    if (!_post.user.username.length && !_post.user.pk.length) return;
    SHProfileViewController *vc = [[SHProfileViewController alloc] initWithUsername:_post.user.username pk:_post.user.pk];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)photoDoubleTapped
{
    if (!_post.hasLiked) [self likeTapped];
}

// shown at once, taken back if Instagram says no
- (void)likeTapped
{
    BOOL willLike = !_post.hasLiked;
    _post.hasLiked = willLike;
    _post.likeCount = MAX(0, _post.likeCount + (willLike ? 1 : -1));
    [self updateLikeUI];
    void (^done)(BOOL, NSError *) = ^(BOOL ok, NSError *err) {
        if (ok) return;
        self->_post.hasLiked = !willLike;
        self->_post.likeCount = MAX(0, self->_post.likeCount + (willLike ? -1 : 1));
        [self updateLikeUI];
    };
    if (willLike) [SHInstagram likePost:_post.pk completion:done];
    else [SHInstagram unlikePost:_post.pk completion:done];
}

- (void)saveTapped
{
    BOOL willSave = !_post.saved;
    _post.saved = willSave;   // optimistic
    [self updateSaveUI];
    void (^done)(BOOL, NSError *) = ^(BOOL ok, NSError *err) {
        if (!ok) { self->_post.saved = !willSave; [self updateSaveUI]; }
    };
    if (willSave) [SHInstagram savePost:_post.pk completion:done];
    else [SHInstagram unsavePost:_post.pk completion:done];
}

- (void)updateLikeUI
{
    SHTheme *theme = [SHTheme shared];
    UIColor *heartColor = _post.hasLiked ? [UIColor colorWithRed:0.93 green:0.2 blue:0.27 alpha:1] : [theme textColor];
    [_likeButton setImage:[SHTabIcons heartWithSize:17 filled:_post.hasLiked color:heartColor dark:theme.isDark] forState:UIControlStateNormal];
    [_likeButton setBackgroundImage:[theme buttonImageHighlighted:_post.hasLiked] forState:UIControlStateNormal];
    _likesLabel.text = [NSString stringWithFormat:L(@"%@ likes"), [SHUtils formatCount:_post.likeCount]];
}

- (void)updateSaveUI
{
    [_saveButton setImage:[SHTabIcons bookmarkWithSize:18 filled:_post.saved color:[[SHTheme shared] textColor] dark:[[SHTheme shared] isDark]]
                 forState:UIControlStateNormal];
}

- (void)showLikers
{
    if (!_post.pk.length || _post.likeCount == 0) return;
    [SHInstagram likersForPost:_post.pk completion:^(NSArray *users, NSError *error) {
        if (error) { [SHUtils alertWithTitle:L(@"Likes") message:error.localizedDescription]; return; }
        SHUserListViewController *vc = [[SHUserListViewController alloc] initWithTitle:L(@"Likes") users:users];
        [self.navigationController pushViewController:vc animated:YES];
    }];
}

- (void)commentsTapped
{
    SHCommentsViewController *vc = [[SHCommentsViewController alloc] initWithPost:_post];
    [SHLinkRouter presentInNavigation:vc];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
