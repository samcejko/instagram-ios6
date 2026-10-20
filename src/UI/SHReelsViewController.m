#import "SHLegacyCollections.h"
#import "SHReelsViewController.h"
#import "SHPostDetailViewController.h"
#import "SHCommentsViewController.h"
#import "SHProfileViewController.h"
#import "SHShareViewController.h"
#import "SHLinkLabel.h"
#import "SHTabIcons.h"
#import "SHInstagram.h"
#import "SHModels.h"
#import "SHImageLoader.h"
#import "SHMediaProxy.h"
#import "SHLinkRouter.h"
#import "SHModern.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHCommon.h"
#import <AVFoundation/AVFoundation.h>

static void *SHReelReadyContext = &SHReelReadyContext;

#pragma mark - A page

@class SHReelPage;
@protocol SHReelPageDelegate <NSObject>
- (void)reelPageTapped:(SHReelPage *)page;
- (void)reelPageDoubleTapped:(SHReelPage *)page;
- (void)reelPage:(SHReelPage *)page action:(NSString *)action;   // "like", "comment", "post", "user", "share"
- (void)reelPage:(SHReelPage *)page openLink:(SHTextLink *)link;  // an @name, #tag or link in the caption
@end

@interface SHReelPage : UIView
@property (nonatomic, weak) id<SHReelPageDelegate> delegate;
@property (nonatomic, strong) SHPost *post;
@property (nonatomic, strong) SHImageView *cover;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIImageView *pausedMark;
@property (nonatomic, strong) UIImageView *shade;
@property (nonatomic, strong) SHImageView *avatar;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) SHLinkLabel *captionLabel;
@property (nonatomic, strong) UIButton *likeButton;
@property (nonatomic, strong) UILabel *likeCount;
@property (nonatomic, strong) UIButton *commentButton;
@property (nonatomic, strong) UIButton *shareButton;
@property (nonatomic, strong) UIButton *postButton;
@property (nonatomic) CGFloat bottomInset;   // the home bar of a phone without a button (kept clear)
- (void)showPost:(SHPost *)post;
- (void)attachPlayer:(AVPlayer *)player;
- (void)detachPlayer;
- (void)setPaused:(BOOL)paused;
- (void)refreshLike;
@end

@implementation SHReelPage

- (UIButton *)roundButton:(UIImage *)glyph action:(SEL)action
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setBackgroundImage:[[SHTheme shared] roundButtonImageWithSize:50] forState:UIControlStateNormal];
    [b setImage:glyph forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b];
    return b;
}

- (UILabel *)shadowLabel:(UIFont *)font
{
    UILabel *l = [[UILabel alloc] init];
    l.font = font;
    l.textColor = [UIColor whiteColor];
    l.backgroundColor = [UIColor clearColor];
    l.shadowColor = [UIColor colorWithWhite:0 alpha:0.8];
    l.shadowOffset = CGSizeMake(0, 1);
    [self addSubview:l];
    return l;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        SHTheme *theme = [SHTheme shared];
        self.backgroundColor = [UIColor blackColor];
        self.clipsToBounds = YES;

        _cover = [[SHImageView alloc] initWithFrame:self.bounds];
        _cover.contentMode = UIViewContentModeScaleAspectFit;
        _cover.maxPixels = 720;
        [self addSubview:_cover];

        _shade = [[UIImageView alloc] initWithImage:[theme controlsGradientImageTop:NO]];
        [self addSubview:_shade];

        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
        _spinner.hidesWhenStopped = YES;
        [self addSubview:_spinner];

        _pausedMark = [[UIImageView alloc] initWithImage:[theme playButtonImageWithSize:80]];
        _pausedMark.hidden = YES;
        [self addSubview:_pausedMark];

        _avatar = [[SHImageView alloc] initWithFrame:CGRectMake(0, 0, 36, 36)];
        [theme styleAvatar:_avatar radius:4];
        _avatar.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.85].CGColor;
        _avatar.maxPixels = 96;
        _avatar.userInteractionEnabled = YES;
        [_avatar addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(userTapped)]];
        [self addSubview:_avatar];
        _nameLabel = [self shadowLabel:[UIFont boldSystemFontOfSize:15]];
        _nameLabel.userInteractionEnabled = YES;
        [_nameLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(userTapped)]];
        // the caption: white over the video, its @names and #tags in bold white
        _captionLabel = [[SHLinkLabel alloc] initWithFrame:CGRectZero];
        _captionLabel.font = [UIFont systemFontOfSize:14];
        _captionLabel.textColor = [UIColor whiteColor];
        _captionLabel.linkColor = [UIColor colorWithRed:0.75 green:0.87 blue:1 alpha:1];
        _captionLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.8];
        _captionLabel.shadowOffset = CGSizeMake(0, 1);
        _captionLabel.numberOfLines = 2;
        __weak SHReelPage *weakSelf = self;
        _captionLabel.linkHandler = ^(SHTextLink *link) {
            SHReelPage *page = weakSelf;
            [page.delegate reelPage:page openLink:link];
        };
        [self addSubview:_captionLabel];

        _likeButton = [self roundButton:nil action:@selector(likeTapped)];
        _likeCount = [self shadowLabel:[UIFont boldSystemFontOfSize:12]];
        _likeCount.textAlignment = UITextAlignmentCenter;
        _commentButton = [self roundButton:[SHTabIcons commentBubbleWithSize:24 color:[UIColor whiteColor] dark:YES] action:@selector(commentTapped)];
        _shareButton = [self roundButton:[SHTabIcons paperPlaneWithSize:24 color:[UIColor whiteColor] dark:YES] action:@selector(shareTapped)];
        _shareButton.accessibilityLabel = L(@"Share");
        _postButton = [self roundButton:[theme carouselGlyph] action:@selector(postTapped)];

        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTapped)];
        doubleTap.numberOfTapsRequired = 2;
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)];
        [tap requireGestureRecognizerToFail:doubleTap];
        [self addGestureRecognizer:tap];
        [self addGestureRecognizer:doubleTap];
    }
    return self;
}

- (void)dealloc { [self detachPlayer]; }

- (void)setBottomInset:(CGFloat)bottomInset
{
    if (_bottomInset == bottomInset) return;
    _bottomInset = bottomInset;
    [self setNeedsLayout];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat w = b.size.width, fullH = b.size.height;
    _cover.frame = b;
    _playerLayer.frame = b;
    _shade.frame = CGRectMake(0, fullH - 200 - _bottomInset, w, 200 + _bottomInset);
    _spinner.center = CGPointMake(w / 2, fullH / 2);
    _pausedMark.frame = CGRectMake(floorf((w - 80) / 2), floorf((fullH - 80) / 2), 80, 80);
    CGFloat h = fullH - _bottomInset;   // the controls sit above the home bar

    CGFloat right = w - 14 - 50;
    _postButton.frame = CGRectMake(right, h - 90, 50, 50);
    _shareButton.frame = CGRectMake(right, h - 150, 50, 50);
    _commentButton.frame = CGRectMake(right, h - 210, 50, 50);
    _likeCount.frame = CGRectMake(right - 10, h - 232, 70, 16);
    _likeButton.frame = CGRectMake(right, h - 286, 50, 50);

    CGFloat textW = right - 14 - 16;
    _captionLabel.frame = CGRectMake(14, h - 64, textW, 40);
    _avatar.frame = CGRectMake(14, h - 108, 36, 36);
    _nameLabel.frame = CGRectMake(58, h - 106, textW - 44, 32);
}

- (void)showPost:(SHPost *)post
{
    _post = post;
    [_cover setImageURL:post.mediumImage.url ?: post.image.url placeholder:nil];
    [_avatar setImageURL:post.user.profilePicURL placeholder:[[SHTheme shared] avatarPlaceholderWithSize:36]];
    _nameLabel.text = post.user.username;
    // (one flowing line of text: the caption's line breaks would waste the two lines it has)
    NSArray *parts = [[SHUtils displayText:post.captionText ?: @""] componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray *kept = [NSMutableArray array];
    for (NSString *p in parts) {
        NSString *t = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [kept addObject:t];
    }
    _captionLabel.text = [kept componentsJoinedByString:@" "];
    _pausedMark.hidden = YES;
    [self refreshLike];
}

- (void)refreshLike
{
    UIColor *color = _post.hasLiked ? [UIColor colorWithRed:0.95 green:0.22 blue:0.3 alpha:1] : [UIColor whiteColor];
    [_likeButton setImage:[SHTabIcons heartWithSize:24 filled:_post.hasLiked color:color dark:YES] forState:UIControlStateNormal];
    _likeCount.text = _post.likeCount > 0 ? [SHUtils formatCount:_post.likeCount] : @"";
}

- (void)attachPlayer:(AVPlayer *)player
{
    [self detachPlayer];
    _playerLayer = [AVPlayerLayer playerLayerWithPlayer:player];
    _playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    _playerLayer.frame = self.bounds;
    [self.layer insertSublayer:_playerLayer above:_cover.layer];
    [_playerLayer addObserver:self forKeyPath:@"readyForDisplay" options:0 context:SHReelReadyContext];
    [_spinner startAnimating];
}

- (void)detachPlayer
{
    if (!_playerLayer) return;
    [_playerLayer removeObserver:self forKeyPath:@"readyForDisplay" context:SHReelReadyContext];
    [_playerLayer removeFromSuperlayer];
    _playerLayer = nil;
    [_spinner stopAnimating];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context != SHReelReadyContext) { [super observeValueForKeyPath:keyPath ofObject:object change:change context:context]; return; }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_playerLayer.readyForDisplay) [self->_spinner stopAnimating];
    });
}

- (void)setPaused:(BOOL)paused { _pausedMark.hidden = !paused; }

- (void)tapped { [_delegate reelPageTapped:self]; }
- (void)doubleTapped { [_delegate reelPageDoubleTapped:self]; }
- (void)likeTapped { [_delegate reelPage:self action:@"like"]; }
- (void)commentTapped { [_delegate reelPage:self action:@"comment"]; }
- (void)shareTapped { [_delegate reelPage:self action:@"share"]; }
- (void)postTapped { [_delegate reelPage:self action:@"post"]; }
- (void)userTapped { [_delegate reelPage:self action:@"user"]; }

@end

#pragma mark - The pager

@interface SHReelsViewController () <UIScrollViewDelegate, SHReelPageDelegate>
@property (nonatomic, copy) SHGridLoader loader;
@property (nonatomic, strong) NSMutableArray *posts;
@property (nonatomic, copy) NSString *nextMaxId;
@property (nonatomic, strong) SHHTTPTask *task;
@property (nonatomic) BOOL loading;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) NSMutableDictionary *pages;      // @(index) -> SHReelPage, for current-1 … current+1
@property (nonatomic) NSInteger current;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic) BOOL visible;
@property (nonatomic) BOOL userPaused;
@property (nonatomic) BOOL hadStatusBar;
@end

@implementation SHReelsViewController

- (instancetype)initWithLoader:(SHGridLoader)loader
{
    if ((self = [super init])) {
        _loader = [loader copy];
        _posts = [NSMutableArray array];
        _pages = [NSMutableDictionary dictionary];
        self.wantsFullScreenLayout = YES;
        self.title = L(@"Reels");   // (what the back button of a screen opened from here says)
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.pagingEnabled = YES;
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.backgroundColor = [UIColor blackColor];
    _scroll.delegate = self;
    [self.view addSubview:_scroll];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.text = L(@"Reels");
    _titleLabel.font = [UIFont boldSystemFontOfSize:18];
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.backgroundColor = [UIColor clearColor];
    _titleLabel.textAlignment = UITextAlignmentCenter;
    _titleLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.8];
    _titleLabel.shadowOffset = CGSizeMake(0, 1);
    [self.view addSubview:_titleLabel];

    _closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [_closeButton setImage:[[SHTheme shared] closeIconWhite] forState:UIControlStateNormal];
    _closeButton.accessibilityLabel = L(@"Done");
    _closeButton.layer.shadowOpacity = 0.7;
    _closeButton.layer.shadowRadius = 1.5;
    _closeButton.layer.shadowOffset = CGSizeMake(0, 1);
    [_closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_closeButton];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    _spinner.hidesWhenStopped = YES;
    [self.view addSubview:_spinner];

    _messageLabel = [[UILabel alloc] init];
    _messageLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    _messageLabel.font = [UIFont boldSystemFontOfSize:16];
    _messageLabel.numberOfLines = 0;
    _messageLabel.textAlignment = UITextAlignmentCenter;
    _messageLabel.backgroundColor = [UIColor clearColor];
    _messageLabel.hidden = YES;
    [self.view addSubview:_messageLabel];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appBecameActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    if (_cachedLoader) {
        __weak SHReelsViewController *weak = self;
        _cachedLoader(^(NSArray *posts, NSString *next, NSError *error) {
            SHReelsViewController *me = weak;
            if (!me || me.posts.count || !posts.count) return;   // (the network was quicker, or nothing was kept)
            [me addPosts:posts];
        });
    }
    [self load:NO];
}

// Adds videos not shown yet (the kept page and a fresh one overlap); the first ones start playing.
- (void)addPosts:(NSArray *)posts
{
    NSUInteger before = _posts.count;
    NSMutableSet *known = [NSMutableSet set];
    for (SHPost *p in _posts) if (p.pk.length) [known addObject:p.pk];
    for (SHPost *p in posts) {
        if (!p.videoURL.length || !p.pk.length || [known containsObject:p.pk]) continue;
        [_posts addObject:p];
        [known addObject:p.pk];
    }
    if (_posts.count == before) return;
    _messageLabel.hidden = YES;
    [_spinner stopAnimating];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    [self refreshWindow];
    if (before == 0 && _visible) [self activate:0];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_task cancel];
    [_player pause];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGSize s = self.view.bounds.size;
    _scroll.contentSize = CGSizeMake(s.width, s.height * MAX(1, (NSInteger)_posts.count));
    // (phones with a notch: the close button and the bottom row keep clear of the sensor housing and the home bar)
    UIEdgeInsets safe = SHSafeAreaInsets(self.view);
    for (NSNumber *k in _pages) {
        SHReelPage *page = [_pages objectForKey:k];
        page.bottomInset = safe.bottom;
        page.frame = CGRectMake(0, s.height * k.integerValue, s.width, s.height);
    }
    if (!_scroll.dragging && !_scroll.decelerating) _scroll.contentOffset = CGPointMake(0, s.height * _current);
    CGFloat top = MAX(18, safe.top);
    _titleLabel.frame = CGRectMake(60, top + 8, s.width - 120, 24);
    _closeButton.frame = CGRectMake(MAX(8, safe.left + 4), top, 44, 44);
    _spinner.center = CGPointMake(s.width / 2, s.height / 2);
    _messageLabel.frame = CGRectMake(30, s.height / 2 - 50, s.width - 60, 100);
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    _hadStatusBar = ![UIApplication sharedApplication].statusBarHidden;
    [[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationFade];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    _visible = YES;
    if (_posts.count && !_userPaused) [self activate:_current];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    _visible = NO;
    [_player pause];
    if (_hadStatusBar) [[UIApplication sharedApplication] setStatusBarHidden:NO withAnimation:UIStatusBarAnimationFade];
}

- (BOOL)prefersStatusBarHidden { return YES; }

- (void)appBecameActive { if (_visible && !_userPaused) [_player play]; }

- (void)closeTapped
{
    [self stopPlayer];
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Loading

- (void)load:(BOOL)more
{
    if (_loading || !_loader) return;
    if (more && !_nextMaxId.length) return;
    _loading = YES;
    if (!_posts.count) { [_spinner startAnimating]; _messageLabel.hidden = YES; }
    __weak SHReelsViewController *weak = self;
    _task = _loader(more ? _nextMaxId : nil, ^(NSArray *posts, NSString *nextMaxId, NSError *error) {
        SHReelsViewController *me = weak;
        if (!me) return;
        me.loading = NO;
        [me.spinner stopAnimating];
        if (error) {
            if (!me.posts.count) { me.messageLabel.text = error.localizedDescription; me.messageLabel.hidden = NO; }
            return;
        }
        me.nextMaxId = nextMaxId;
        NSUInteger before = me.posts.count;
        [me addPosts:posts];
        if (!me.posts.count) { me.messageLabel.text = L(@"Nothing here yet."); me.messageLabel.hidden = NO; return; }
        // a page that brought nothing new: ask for the next one straight away
        if (me.posts.count == before && nextMaxId.length) [me load:YES];
    });
}

- (SHPost *)postAt:(NSInteger)i { return (i >= 0 && i < (NSInteger)_posts.count) ? [_posts objectAtIndex:(NSUInteger)i] : nil; }

#pragma mark - Pages

// keeps pages for current-1 … current+1 and lets go of the rest
- (void)refreshWindow
{
    CGSize s = _scroll.bounds.size;
    for (NSNumber *k in [_pages allKeys]) {
        if (labs(k.integerValue - _current) > 1) {
            SHReelPage *page = [_pages objectForKey:k];
            [page detachPlayer];
            [page removeFromSuperview];
            [_pages removeObjectForKey:k];
        }
    }
    for (NSInteger i = _current - 1; i <= _current + 1; i++) {
        SHPost *p = [self postAt:i];
        if (!p || [_pages objectForKey:@(i)]) continue;
        SHReelPage *page = [[SHReelPage alloc] initWithFrame:CGRectMake(0, s.height * i, s.width, s.height)];
        page.bottomInset = SHSafeAreaInsets(self.view).bottom;
        page.delegate = self;
        [page showPost:p];
        [_scroll addSubview:page];
        SHLegacyDictionarySet(_pages, @(i), page);
    }
    if ((NSUInteger)_current + 3 >= _posts.count) [self load:YES];
}

- (void)stopPlayer
{
    [_player pause];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
    for (NSNumber *k in _pages) [[_pages objectForKey:k] detachPlayer];
    _player = nil;
}

// Plays the page at `index` (over the app's media proxy: iOS 6 cannot speak the CDN's TLS itself), looping.
- (void)activate:(NSInteger)index
{
    [self stopPlayer];
    SHPost *p = [self postAt:index];
    SHReelPage *page = [_pages objectForKey:@(index)];
    if (!p.videoURL.length || !page) return;
    NSString *proxied = [[SHMediaProxy shared] proxyURLForURL:[NSURL URLWithString:p.videoURL]];
    if (!proxied.length) return;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL URLWithString:proxied]];
    _player = [AVPlayer playerWithPlayerItem:item];
    _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemEnded:) name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    [page attachPlayer:_player];
    [page setPaused:NO];
    _userPaused = NO;
    [_player play];
}

- (void)itemEnded:(NSNotification *)note
{
    [_player seekToTime:kCMTimeZero];
    [_player play];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView { [self pageSettled]; }
- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView { [self pageSettled]; }

- (void)pageSettled
{
    CGFloat h = _scroll.bounds.size.height;
    NSInteger page = h > 0 ? (NSInteger)(_scroll.contentOffset.y / h + 0.5) : 0;
    page = MAX(0, MIN(page, (NSInteger)_posts.count - 1));
    if (page == _current) return;
    _current = page;
    [self refreshWindow];
    [self activate:page];
}

#pragma mark - SHReelPageDelegate

- (void)reelPageTapped:(SHReelPage *)page
{
    if (!_player) return;
    BOOL playing = _player.rate > 0;
    if (playing) [_player pause]; else [_player play];
    _userPaused = playing;
    [page setPaused:playing];
}

- (void)reelPageDoubleTapped:(SHReelPage *)page
{
    if (!page.post.hasLiked) [self reelPage:page action:@"like"];
}

- (void)reelPage:(SHReelPage *)page action:(NSString *)action
{
    SHPost *post = page.post;
    if (!post) return;
    if ([action isEqualToString:@"like"]) {
        BOOL willLike = !post.hasLiked;
        post.hasLiked = willLike;
        post.likeCount = MAX(0, post.likeCount + (willLike ? 1 : -1));
        [page refreshLike];
        void (^done)(BOOL, NSError *) = ^(BOOL ok, NSError *err) {
            if (ok) return;
            post.hasLiked = !willLike;
            post.likeCount = MAX(0, post.likeCount + (willLike ? -1 : 1));
            if (page.post == post) [page refreshLike];
        };
        if (willLike) [SHInstagram likePost:post.pk completion:done];
        else [SHInstagram unlikePost:post.pk completion:done];
    } else if ([action isEqualToString:@"comment"]) {
        [self presentOver:[[SHCommentsViewController alloc] initWithPost:post]];
    } else if ([action isEqualToString:@"post"]) {
        [self presentOver:[[SHPostDetailViewController alloc] initWithPost:post]];
    } else if ([action isEqualToString:@"user"]) {
        if (!post.user.username.length && !post.user.pk.length) return;
        [self presentOver:[[SHProfileViewController alloc] initWithUsername:post.user.username pk:post.user.pk]];
    } else if ([action isEqualToString:@"share"]) {
        [_player pause];
        [SHShareViewController presentForPost:post];
    }
}

// The comments, the post or the creator's profile over the reels, with a back button ("< Reels"); the video waits
// and plays on when that closes.
- (void)presentOver:(UIViewController *)controller
{
    [_player pause];
    __weak SHReelsViewController *weakSelf = self;
    [SHLinkRouter presentInNavigation:controller onClose:^{
        SHReelsViewController *s = weakSelf;
        if (s && s.visible && !s.userPaused && s.view.window) [s.player play];
    }];
}

// A link in the caption: the video stops, the profile, tag or post opens over the player (closing it plays on).
- (void)reelPage:(SHReelPage *)page openLink:(SHTextLink *)link
{
    [_player pause];
    _userPaused = YES;
    [page setPaused:YES];
    [SHLinkLabel openLink:link from:page];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
