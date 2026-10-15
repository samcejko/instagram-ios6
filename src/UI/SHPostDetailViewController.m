#import "SHPostDetailViewController.h"
#import "SHTabIcons.h"
#import "SHCommentsViewController.h"
#import "SHProfileViewController.h"
#import "SHUserListViewController.h"
#import "SHShareViewController.h"
#import "SHLinkLabel.h"
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
@property (nonatomic, strong) NSMutableArray *tagLayers;   // per picture: the bubbles of the people tagged on it
@property (nonatomic, strong) NSMutableArray *tagUsers;    // SHUser, by the bubble's tag
@property (nonatomic, strong) UIView *contentView;         // everything in the scroll view, built for one width
@property (nonatomic) CGFloat builtWidth;
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

    _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scrollView.indicatorStyle = theme.isDark ? UIScrollViewIndicatorStyleWhite : UIScrollViewIndicatorStyleDefault;
    [self.view addSubview:_scrollView];
    [self buildContent];
}

// Laid out for the width the screen had when it loaded; turned, or opened while the iPad lies on its side (iOS 6
// loads the view in the upright size first), the post is laid out again for the width it really has.
- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    if (fabs(self.view.bounds.size.width - _builtWidth) > 1) [self buildContent];
}

- (void)buildContent
{
    SHTheme *theme = [SHTheme shared];
    CGFloat w = self.view.bounds.size.width;
    _builtWidth = w;
    NSInteger page = _pageControl.currentPage;
    BOOL tagsShown = _tagLayers.count && ![_tagLayers.firstObject isHidden];
    [_contentView removeFromSuperview];
    _contentView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 0)];
    _contentView.backgroundColor = [UIColor clearColor];
    [_scrollView addSubview:_contentView];
    _pageControl = nil;
    _carousel = nil;

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
    [_contentView addSubview:header];

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
        [_contentView addSubview:poster];
        BOOL started = _player != nil && _player.playbackState != MPMoviePlaybackStateStopped;
        if (!_player) {   // (laid out again: the same player goes on where it was)
            NSString *proxied = [[SHMediaProxy shared] proxyURLForURL:[NSURL URLWithString:_post.videoURL]];
            _player = [[MPMoviePlayerController alloc] initWithContentURL:[NSURL URLWithString:proxied]];
            _player.view.backgroundColor = [UIColor clearColor];
            _player.backgroundView.backgroundColor = [UIColor clearColor];   // the poster shows until it plays
            _player.controlStyle = MPMovieControlStyleEmbedded;
            _player.shouldAutoplay = NO;
        }
        _player.view.frame = CGRectMake(0, top, w, imgH);
        [_contentView addSubview:_player.view];
        // a glossy play button over the poster starts it
        if (!started) {
            UIButton *play = [UIButton buttonWithType:UIButtonTypeCustom];
            [play setImage:[theme playButtonImageWithSize:72] forState:UIControlStateNormal];
            play.frame = CGRectMake(floorf((w - 72) / 2), top + floorf((imgH - 72) / 2), 72, 72);
            [play addTarget:self action:@selector(playTapped:) forControlEvents:UIControlEventTouchUpInside];
            [_contentView addSubview:play];
        }
    } else {
        _carousel = [[UIScrollView alloc] initWithFrame:CGRectMake(0, top, w, imgH)];
        _carousel.pagingEnabled = YES;
        _carousel.showsHorizontalScrollIndicator = NO;
        _carousel.delegate = self;
        _carousel.contentSize = CGSizeMake(w * items.count, imgH);
        _tagLayers = [NSMutableArray array];
        _tagUsers = [NSMutableArray array];
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
            // one tap shows the people tagged on the picture (and hides them again), as in the app
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(photoTapped)];
            [tap requireGestureRecognizerToFail:doubleTap];
            [iv addGestureRecognizer:tap];
            [iv setImageURL:item.image.url placeholder:nil];
            NSArray *tags = item.userTags.count ? item.userTags : (items.count == 1 ? _post.userTags : nil);
            if (tags.count) {
                UIView *layer = [self tagLayerForTags:tags image:item.image ?: _post.image size:CGSizeMake(w, imgH)];
                layer.hidden = YES;
                [iv addSubview:layer];
                [_tagLayers addObject:layer];
                // the hint the app shows: a person in a dark disc in the corner
                UIImageView *badge = [[UIImageView alloc] initWithImage:[theme roundButtonImageWithSize:28]];
                badge.frame = CGRectMake(10, imgH - 38, 28, 28);
                UIImageView *person = [[UIImageView alloc] initWithImage:[SHTabIcons personWithSize:14 color:[UIColor whiteColor] dark:YES]];
                person.frame = CGRectMake(7, 6, person.image.size.width, person.image.size.height);
                [badge addSubview:person];
                [iv addSubview:badge];
            }
            [_carousel addSubview:iv];
        }
        [_contentView addSubview:_carousel];
        if (items.count > 1) {
            _pageControl = [[UIPageControl alloc] initWithFrame:CGRectMake(0, top + imgH - 24, w, 16)];
            _pageControl.numberOfPages = (NSInteger)items.count;
            _pageControl.userInteractionEnabled = NO;
            [_contentView addSubview:_pageControl];
            // the same picture as before it was laid out again
            NSInteger keep = MAX(0, MIN(page, (NSInteger)items.count - 1));
            _pageControl.currentPage = keep;
            _carousel.contentOffset = CGPointMake(w * (CGFloat)keep, 0);
        }
        for (UIView *layer in _tagLayers) layer.hidden = !tagsShown;
    }

    CGFloat y = top + imgH + 8;

    // glossy Like / Comment / share buttons and the bookmark, as in the app of the iOS 6 days (only the glyphs where
    // the words would not fit: a phone in Czech)
    CGFloat likeW = MAX(110, [L(@"Like") sizeWithFont:[UIFont boldSystemFontOfSize:13]].width + 50);
    CGFloat commentW = MAX(110, [L(@"Comment") sizeWithFont:[UIFont boldSystemFontOfSize:13]].width + 50);
    BOOL compact = 10 + likeW + 8 + commentW + 8 + 46 + 8 + 42 + 10 > w;
    if (compact) likeW = commentW = 56;
    _likeButton = [self glossyButton:compact ? nil : L(@"Like") image:nil action:@selector(likeTapped)];
    _likeButton.frame = CGRectMake(10, y, likeW, 32);
    _likeButton.accessibilityLabel = L(@"Like");
    [_contentView addSubview:_likeButton];

    UIButton *commentButton = [self glossyButton:compact ? nil : L(@"Comment")
                                           image:[SHTabIcons commentBubbleWithSize:17 color:[theme textColor] dark:theme.isDark]
                                          action:@selector(commentsTapped)];
    commentButton.frame = CGRectMake(10 + likeW + 8, y, commentW, 32);
    commentButton.accessibilityLabel = L(@"Comment");
    [_contentView addSubview:commentButton];

    UIButton *shareButton = [self glossyButton:nil image:[SHTabIcons paperPlaneWithSize:18 color:[theme textColor] dark:theme.isDark]
                                        action:@selector(shareTapped)];
    shareButton.frame = CGRectMake(CGRectGetMaxX(commentButton.frame) + 8, y, 46, 32);
    shareButton.accessibilityLabel = L(@"Share");
    [_contentView addSubview:shareButton];

    _saveButton = [self glossyButton:nil image:nil action:@selector(saveTapped)];
    _saveButton.frame = CGRectMake(w - 52, y, 42, 32);
    [_contentView addSubview:_saveButton];
    y += 32 + 10;

    UIImageView *heart = [[UIImageView alloc] initWithImage:[SHTabIcons heartWithSize:14 filled:YES color:[theme linkColor] dark:theme.isDark]];
    heart.frame = CGRectMake(12, y + 3, heart.image.size.width, heart.image.size.height);
    [_contentView addSubview:heart];
    _likesLabel = [[UILabel alloc] initWithFrame:CGRectMake(32, y, w - 44, 20)];
    _likesLabel.font = [UIFont boldSystemFontOfSize:14];
    _likesLabel.textColor = [theme linkColor];
    _likesLabel.backgroundColor = [UIColor clearColor];
    [theme embossLabel:_likesLabel];
    _likesLabel.userInteractionEnabled = YES;
    [_likesLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showLikers)]];
    [_contentView addSubview:_likesLabel];
    [self updateLikeUI];
    [self updateSaveUI];
    y += 26;

    if (_post.captionText.length) {
        // the caption with its @names, #tags and links live; the author's name in front opens the profile
        SHLinkLabel *caption = [[SHLinkLabel alloc] initWithFrame:CGRectMake(12, y, w - 24, 0)];
        caption.shadowColor = theme.isDark ? [UIColor colorWithWhite:0 alpha:0.8] : [UIColor colorWithWhite:1 alpha:0.9];
        caption.shadowOffset = theme.isDark ? CGSizeMake(0, -1) : CGSizeMake(0, 1);
        NSString *user = _post.user.username ?: @"";
        NSString *text = [NSString stringWithFormat:@"%@ %@", user, [SHUtils displayText:_post.captionText]];
        NSMutableAttributedString *cap = [[NSMutableAttributedString alloc] initWithString:text attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:14], NSForegroundColorAttributeName: [theme textColor] }];
        NSRange nameRange = NSMakeRange(0, MIN(user.length, text.length));
        [cap addAttributes:@{ NSFontAttributeName: [UIFont boldSystemFontOfSize:14], NSForegroundColorAttributeName: [theme linkColor] }
                     range:nameRange];
        caption.attributedText = cap;
        [caption addUserLinkWithRange:nameRange username:user pk:_post.user.pk];
        CGSize sz = [caption sizeThatFits:CGSizeMake(w - 24, 0)];
        caption.frame = CGRectMake(12, y, w - 24, sz.height);
        [_contentView addSubview:caption];
        y += sz.height + 12;
    }

    _contentView.frame = CGRectMake(0, 0, w, y + 20);
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

#pragma mark - People tagged on the photo

// A dark see-through bubble with the name and a small point on top that touches the tagged spot.
- (UIImage *)tagBubbleImage:(NSString *)name
{
    UIFont *font = [UIFont boldSystemFontOfSize:13];
    CGSize ts = [name sizeWithFont:font];
    CGFloat w = ceilf(ts.width) + 20, h = 26, point = 6;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h + point), NO, 0);
    UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, point, w, h) cornerRadius:5];
    [shape moveToPoint:CGPointMake(w / 2 - point, point)];
    [shape addLineToPoint:CGPointMake(w / 2, 0)];
    [shape addLineToPoint:CGPointMake(w / 2 + point, point)];
    [shape closePath];
    [[UIColor colorWithWhite:0 alpha:0.78f] setFill];
    [shape fill];
    [[UIColor colorWithWhite:1 alpha:0.12f] setFill];   // the gloss of the upper half
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(1, point + 1, w - 2, h / 2 - 1) cornerRadius:4] fill];
    [[UIColor whiteColor] setFill];
    [name drawInRect:CGRectMake(10, point + floorf((h - ts.height) / 2), ceilf(ts.width), ts.height) withFont:font];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// The bubbles over one picture shown filled into `size` (cut at the sides like the picture is).
- (UIView *)tagLayerForTags:(NSArray *)tags image:(SHMediaImage *)image size:(CGSize)size
{
    UIView *layer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size.width, size.height)];
    layer.backgroundColor = [UIColor clearColor];
    CGFloat iw = image.width > 0 ? image.width : size.width, ih = image.height > 0 ? image.height : size.height;
    CGFloat scale = MAX(size.width / iw, size.height / ih);
    CGFloat dw = iw * scale, dh = ih * scale, ox = (size.width - dw) / 2, oy = (size.height - dh) / 2;
    for (SHUserTag *tag in tags) {
        UIImage *bubble = [self tagBubbleImage:tag.user.username];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        [b setImage:bubble forState:UIControlStateNormal];
        CGPoint p = CGPointMake(ox + (CGFloat)tag.x * dw, oy + (CGFloat)tag.y * dh);
        CGFloat bx = MAX(4, MIN(size.width - bubble.size.width - 4, p.x - bubble.size.width / 2));
        CGFloat by = MAX(4, MIN(size.height - bubble.size.height - 4, p.y));
        b.frame = CGRectMake(floorf(bx), floorf(by), bubble.size.width, bubble.size.height);
        b.tag = (NSInteger)_tagUsers.count;
        b.accessibilityLabel = tag.user.username;
        [_tagUsers addObject:tag.user];
        [b addTarget:self action:@selector(tagTapped:) forControlEvents:UIControlEventTouchUpInside];
        [layer addSubview:b];
    }
    return layer;
}

- (void)photoTapped
{
    if (!_tagLayers.count) return;
    BOOL show = [_tagLayers.firstObject isHidden];
    for (UIView *layer in _tagLayers) {
        layer.alpha = show ? 0 : 1;
        layer.hidden = NO;
    }
    [UIView animateWithDuration:0.2 animations:^{
        for (UIView *layer in self->_tagLayers) layer.alpha = show ? 1 : 0;
    } completion:^(BOOL finished) {
        for (UIView *layer in self->_tagLayers) layer.hidden = !show;
    }];
}

- (void)tagTapped:(UIButton *)button
{
    if (button.tag < 0 || button.tag >= (NSInteger)_tagUsers.count) return;
    SHUser *u = _tagUsers[(NSUInteger)button.tag];
    SHProfileViewController *vc = [[SHProfileViewController alloc] initWithUsername:u.username pk:u.pk];
    if (self.navigationController) [self.navigationController pushViewController:vc animated:YES];
}

- (void)shareTapped
{
    [_player pause];
    [SHShareViewController presentForPost:_post];
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
