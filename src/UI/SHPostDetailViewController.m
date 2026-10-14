#import "SHPostDetailViewController.h"
#import "SHCommentsViewController.h"
#import "SHProfileViewController.h"
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

@interface SHPostDetailViewController ()
@property (nonatomic, strong) SHPost *post;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) SHImageView *imageView;
@property (nonatomic, strong) UILabel *captionLabel;
@property (nonatomic, strong) UILabel *likesLabel;
@property (nonatomic, strong) UIButton *likeButton;
@property (nonatomic, strong) MPMoviePlayerController *player;
@end

@implementation SHPostDetailViewController

- (instancetype)initWithPost:(SHPost *)post
{
    if ((self = [super init])) _post = post;
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = _post.user.username.length ? [@"@" stringByAppendingString:_post.user.username] : L(@"Post");
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
    }

    _imageView = [[SHImageView alloc] initWithFrame:CGRectMake(0, 0, w, imgH)];
    _imageView.contentMode = UIViewContentModeScaleAspectFill;
    _imageView.clipsToBounds = YES;
    _imageView.backgroundColor = [[SHTheme shared] separatorColor];
    [_imageView setImageURL:_post.image.url placeholder:nil];
    [_scrollView addSubview:_imageView];

    CGFloat y = imgH + 8;

    if (_post.videoURL.length) {
        NSString *proxied = [[SHMediaProxy shared] proxyURLForURL:[NSURL URLWithString:_post.videoURL]];
        _player = [[MPMoviePlayerController alloc] initWithContentURL:[NSURL URLWithString:proxied]];
        _player.view.frame = CGRectMake(0, 0, w, imgH);
        _player.controlStyle = MPMovieControlStyleEmbedded;
        _player.shouldAutoplay = NO;
        [_scrollView addSubview:_player.view];
    }

    _likeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _likeButton.frame = CGRectMake(12, y, 30, 30);
    [_likeButton setTitle:@"♥" forState:UIControlStateNormal];
    _likeButton.titleLabel.font = [UIFont systemFontOfSize:26];
    [_likeButton setTitleColor:_post.hasLiked ? [UIColor redColor] : [[SHTheme shared] textColor] forState:UIControlStateNormal];
    [_likeButton addTarget:self action:@selector(likeTapped) forControlEvents:UIControlEventTouchUpInside];
    [_scrollView addSubview:_likeButton];

    _likesLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, y + 32, w - 24, 18)];
    _likesLabel.font = [UIFont boldSystemFontOfSize:14];
    _likesLabel.textColor = [[SHTheme shared] textColor];
    _likesLabel.text = [NSString stringWithFormat:L(@"%@ likes"), [SHUtils formatCount:_post.likeCount]];
    [_scrollView addSubview:_likesLabel];
    y += 56;

    if (_post.captionText.length) {
        _captionLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, y, w - 24, 0)];
        _captionLabel.numberOfLines = 0;
        _captionLabel.font = [UIFont systemFontOfSize:14];
        _captionLabel.textColor = [[SHTheme shared] textColor];
        _captionLabel.text = [SHUtils displayText:_post.captionText];
        CGSize sz = [_captionLabel sizeThatFits:CGSizeMake(w - 24, 9999)];
        _captionLabel.frame = CGRectMake(12, y, w - 24, sz.height);
        [_scrollView addSubview:_captionLabel];
        y += sz.height + 12;
    }

    _scrollView.contentSize = CGSizeMake(w, y + 20);
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

- (void)updateLikeUI
{
    [_likeButton setTitleColor:_post.hasLiked ? [UIColor redColor] : [[SHTheme shared] textColor] forState:UIControlStateNormal];
    _likesLabel.text = [NSString stringWithFormat:L(@"%@ likes"), [SHUtils formatCount:_post.likeCount]];
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
