#import "SHStoryViewController.h"
#import "SHModels.h"
#import "SHImageLoader.h"
#import "SHMediaProxy.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHCommon.h"
#import <MediaPlayer/MediaPlayer.h>

static const NSTimeInterval SHStoryDuration = 5.0;

@interface SHStoryViewController ()
@property (nonatomic, strong) NSArray *reels;
@property (nonatomic) NSUInteger reelIndex;
@property (nonatomic) NSUInteger itemIndex;
@property (nonatomic, strong) SHImageView *imageView;
@property (nonatomic, strong) MPMoviePlayerController *player;
@property (nonatomic, strong) UILabel *usernameLabel;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UIView *progressContainer;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) UIView *progressFill;
@end

@implementation SHStoryViewController

- (instancetype)initWithReels:(NSArray *)reels startIndex:(NSUInteger)index
{
    if ((self = [super init])) {
        _reels = reels;
        _reelIndex = index;
        _itemIndex = 0;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    _imageView = [[SHImageView alloc] initWithFrame:self.view.bounds];
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_imageView];

    CGFloat top = 30;
    _progressContainer = [[UIView alloc] initWithFrame:CGRectMake(8, top, self.view.bounds.size.width - 16, 2)];
    _progressContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _progressContainer.backgroundColor = [UIColor colorWithWhite:1 alpha:0.3];
    _progressContainer.layer.cornerRadius = 1;
    [self.view addSubview:_progressContainer];

    _progressFill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 2)];
    _progressFill.backgroundColor = [UIColor whiteColor];
    _progressFill.layer.cornerRadius = 1;
    [_progressContainer addSubview:_progressFill];

    _usernameLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, top + 8, self.view.bounds.size.width - 60, 20)];
    _usernameLabel.font = [UIFont boldSystemFontOfSize:14];
    _usernameLabel.textColor = [UIColor whiteColor];
    _usernameLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:_usernameLabel];

    _timeLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, top + 28, self.view.bounds.size.width - 60, 16)];
    _timeLabel.font = [UIFont systemFontOfSize:11];
    _timeLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    _timeLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:_timeLabel];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(self.view.bounds.size.width - 44, top + 6, 36, 36);
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:20];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    UITapGestureRecognizer *tapRight = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapNext)];
    UITapGestureRecognizer *tapLeft = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapPrev)];
    UIView *rightZone = [[UIView alloc] initWithFrame:CGRectMake(self.view.bounds.size.width / 2, 0, self.view.bounds.size.width / 2, self.view.bounds.size.height)];
    rightZone.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [rightZone addGestureRecognizer:tapRight];
    [self.view addSubview:rightZone];

    UIView *leftZone = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width / 2, self.view.bounds.size.height)];
    leftZone.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [leftZone addGestureRecognizer:tapLeft];
    [self.view addSubview:leftZone];

    [self showCurrentItem];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [_timer invalidate];
    [_player stop];
}

- (SHStoryReel *)currentReel
{
    if (_reelIndex >= _reels.count) return nil;
    return _reels[_reelIndex];
}

- (SHStoryItem *)currentItem
{
    SHStoryReel *reel = [self currentReel];
    if (!reel || _itemIndex >= reel.items.count) return nil;
    return reel.items[_itemIndex];
}

- (void)showCurrentItem
{
    [_timer invalidate];
    [_player stop];
    _player = nil;

    SHStoryReel *reel = [self currentReel];
    SHStoryItem *item = [self currentItem];
    if (!reel || !item) { [self closeTapped]; return; }

    _usernameLabel.text = reel.user.username;
    _timeLabel.text = item.takenAt ? [SHUtils formatRelativeDate:item.takenAt] : @"";
    _progressFill.frame = CGRectMake(0, 0, 0, 2);

    if (item.mediaType == 2 && item.videoURL.length) {
        _imageView.image = nil;
        NSString *proxied = [[SHMediaProxy shared] proxyURLForURL:[NSURL URLWithString:item.videoURL]];
        _player = [[MPMoviePlayerController alloc] initWithContentURL:[NSURL URLWithString:proxied]];
        _player.view.frame = self.view.bounds;
        _player.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _player.controlStyle = MPMovieControlStyleNone;
        _player.shouldAutoplay = YES;
        [self.view insertSubview:_player.view belowSubview:_progressContainer];

        NSTimeInterval dur = item.videoDuration > 0 ? item.videoDuration : 15;
        [self startTimerWithDuration:dur];
    } else {
        [_imageView setImageURL:item.image.url placeholder:nil];
        [self startTimerWithDuration:SHStoryDuration];
    }
}

- (void)startTimerWithDuration:(NSTimeInterval)duration
{
    __block NSTimeInterval elapsed = 0;
    CGFloat barW = _progressContainer.bounds.size.width;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(timerTick:) userInfo:@(duration) repeats:YES];

    (void)elapsed;
    (void)barW;
}

- (void)timerTick:(NSTimer *)t
{
    NSTimeInterval duration = [t.userInfo doubleValue];
    CGFloat barW = _progressContainer.bounds.size.width;
    CGRect f = _progressFill.frame;
    f.size.width += barW * 0.05 / duration;
    if (f.size.width >= barW) {
        f.size.width = barW;
        _progressFill.frame = f;
        [self advanceItem];
        return;
    }
    _progressFill.frame = f;
}

- (void)advanceItem
{
    SHStoryReel *reel = [self currentReel];
    if (reel && _itemIndex + 1 < reel.items.count) {
        _itemIndex++;
    } else if (_reelIndex + 1 < _reels.count) {
        _reelIndex++;
        _itemIndex = 0;
    } else {
        [self closeTapped];
        return;
    }
    [self showCurrentItem];
}

- (void)tapNext { [self advanceItem]; }

- (void)tapPrev
{
    if (_itemIndex > 0) {
        _itemIndex--;
    } else if (_reelIndex > 0) {
        _reelIndex--;
        SHStoryReel *reel = [self currentReel];
        _itemIndex = reel.items.count > 0 ? reel.items.count - 1 : 0;
    }
    [self showCurrentItem];
}

- (void)closeTapped
{
    [_timer invalidate];
    [_player stop];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (BOOL)prefersStatusBarHidden { return YES; }

@end
