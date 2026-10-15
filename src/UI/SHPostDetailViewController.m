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

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = _post.user.username.length ? _post.user.username : L(@"Post");
    self.view.backgroundColor = [[SHTheme shared] backgroundColor];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:L(@"Comments")
        style:UIBarButtonItemStylePlain target:self action:@selector(commentsTapped)];

    CGFloat w = self.view.bounds.size.width;
    _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_scrollView];

    CGFloat imgH = w;
    if (_post.image && _post.image.width > 0 && _post.image.height > 0) {
        imgH = w * ((CGFloat)_post.image.height / (CGFloat)_post.image.width);
        if (imgH > w * 1.5) imgH = w * 1.5;
        if (imgH < w * 0.6) imgH = w * 0.6;
    }

    NSArray *items = [self mediaItems];
    BOOL isVideo = _post.carouselMedia.count <= 1 && _post.videoURL.length > 0;

    if (isVideo) {
        SHImageView *poster = [[SHImageView alloc] initWithFrame:CGRectMake(0, 0, w, imgH)];
        poster.contentMode = UIViewContentModeScaleAspectFill;
        poster.clipsToBounds = YES;
        poster.backgroundColor = [[SHTheme shared] separatorColor];
        [poster setImageURL:_post.image.url placeholder:nil];
        [_scrollView addSubview:poster];
        NSString *proxied = [[SHMediaProxy shared] proxyURLForURL:[NSURL URLWithString:_post.videoURL]];
        _player = [[MPMoviePlayerController alloc] initWithContentURL:[NSURL URLWithString:proxied]];
        _player.view.frame = CGRectMake(0, 0, w, imgH);
        _player.controlStyle = MPMovieControlStyleEmbedded;
        _player.shouldAutoplay = NO;
        [_scrollView addSubview:_player.view];
    } else {
        _carousel = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, w, imgH)];
        _carousel.pagingEnabled = YES;
        _carousel.showsHorizontalScrollIndicator = NO;
        _carousel.delegate = self;
        _carousel.contentSize = CGSizeMake(w * items.count, imgH);
        for (NSUInteger i = 0; i < items.count; i++) {
            SHPost *item = items[i];
            SHImageView *iv = [[SHImageView alloc] initWithFrame:CGRectMake(w * (CGFloat)i, 0, w, imgH)];
            iv.contentMode = UIViewContentModeScaleAspectFill;
            iv.clipsToBounds = YES;
            iv.backgroundColor = [[SHTheme shared] separatorColor];
            [iv setImageURL:item.image.url placeholder:nil];
            [_carousel addSubview:iv];
        }
        [_scrollView addSubview:_carousel];
        if (items.count > 1) {
            _pageControl = [[UIPageControl alloc] initWithFrame:CGRectMake(0, imgH - 24, w, 16)];
            _pageControl.numberOfPages = (NSInteger)items.count;
            _pageControl.userInteractionEnabled = NO;
            [_scrollView addSubview:_pageControl];
        }
    }

    CGFloat y = imgH + 8;

    // the action glyphs are drawn in code with the iOS 6 emboss (no emoji, which would render in colour)
    _likeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _likeButton.frame = CGRectMake(10, y, 36, 32);
    [_likeButton addTarget:self action:@selector(likeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self updateLikeUI];
    [_scrollView addSubview:_likeButton];

    UIButton *commentButton = [UIButton buttonWithType:UIButtonTypeCustom];
    commentButton.frame = CGRectMake(50, y, 40, 32);
    [commentButton setImage:[SHTabIcons commentBubbleWithSize:26 color:[[SHTheme shared] textColor] dark:[[SHTheme shared] isDark]]
                   forState:UIControlStateNormal];
    [commentButton addTarget:self action:@selector(commentsTapped) forControlEvents:UIControlEventTouchUpInside];
    [_scrollView addSubview:commentButton];

    _saveButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _saveButton.frame = CGRectMake(w - 46, y, 36, 32);
    [_saveButton addTarget:self action:@selector(saveTapped) forControlEvents:UIControlEventTouchUpInside];
    [self updateSaveUI];
    [_scrollView addSubview:_saveButton];

    _likesLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, y + 34, w - 24, 18)];
    _likesLabel.font = [UIFont boldSystemFontOfSize:14];
    _likesLabel.textColor = [[SHTheme shared] textColor];
    _likesLabel.backgroundColor = [UIColor clearColor];
    _likesLabel.userInteractionEnabled = YES;
    [_likesLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showLikers)]];
    [self updateLikeUI];
    [_scrollView addSubview:_likesLabel];
    y += 58;

    if (_post.captionText.length) {
        UILabel *caption = [[UILabel alloc] initWithFrame:CGRectMake(12, y, w - 24, 0)];
        caption.numberOfLines = 0;
        caption.font = [UIFont systemFontOfSize:14];
        caption.textColor = [[SHTheme shared] textColor];
        caption.backgroundColor = [UIColor clearColor];
        NSString *user = _post.user.username.length ? [_post.user.username stringByAppendingString:@"  "] : @"";
        caption.text = [user stringByAppendingString:[SHUtils displayText:_post.captionText]];
        CGSize sz = [caption sizeThatFits:CGSizeMake(w - 24, 9999)];
        caption.frame = CGRectMake(12, y, w - 24, sz.height);
        [_scrollView addSubview:caption];
        y += sz.height + 10;
    }

    if (_post.takenAt) {
        UILabel *date = [[UILabel alloc] initWithFrame:CGRectMake(12, y, w - 24, 16)];
        date.font = [UIFont systemFontOfSize:11];
        date.textColor = [[SHTheme shared] secondaryTextColor];
        date.backgroundColor = [UIColor clearColor];
        date.text = [[SHUtils formatRelativeDate:_post.takenAt] uppercaseString];
        [_scrollView addSubview:date];
        y += 22;
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

- (void)likeTapped
{
    BOOL willLike = !_post.hasLiked;
    if (willLike) {
        [SHInstagram likePost:_post.pk completion:^(BOOL ok, NSError *err) {
            if (ok) { self->_post.hasLiked = YES; self->_post.likeCount++; [self updateLikeUI]; }
        }];
    } else {
        [SHInstagram unlikePost:_post.pk completion:^(BOOL ok, NSError *err) {
            if (ok) { self->_post.hasLiked = NO; self->_post.likeCount = MAX(0, self->_post.likeCount - 1); [self updateLikeUI]; }
        }];
    }
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
    UIColor *heartColor = _post.hasLiked ? [UIColor colorWithRed:0.93 green:0.2 blue:0.27 alpha:1] : [[SHTheme shared] textColor];
    [_likeButton setImage:[SHTabIcons heartWithSize:26 filled:_post.hasLiked color:heartColor dark:[[SHTheme shared] isDark]]
                 forState:UIControlStateNormal];
    _likesLabel.text = [NSString stringWithFormat:L(@"%@ likes"), [SHUtils formatCount:_post.likeCount]];
}

- (void)updateSaveUI
{
    [_saveButton setImage:[SHTabIcons bookmarkWithSize:26 filled:_post.saved color:[[SHTheme shared] textColor] dark:[[SHTheme shared] isDark]]
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
