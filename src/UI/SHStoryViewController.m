#import "SHStoryViewController.h"
#import "SHModels.h"
#import "SHInstagram.h"
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
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) id imageToken;
@property (nonatomic) NSUInteger showSerial;
@property (nonatomic, strong) SHHTTPTask *fetchTask;   // the items of a tray reel that came without them
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
    _usernameLabel.backgroundColor = [UIColor clearColor];
    _usernameLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:_usernameLabel];

    _timeLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, top + 28, self.view.bounds.size.width - 60, 16)];
    _timeLabel.font = [UIFont systemFontOfSize:11];
    _timeLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    _timeLabel.backgroundColor = [UIColor clearColor];
    _timeLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:_timeLabel];

    // Tap zones go UNDER the controls (otherwise the close button is unreachable); a swipe down also closes.
    UITapGestureRecognizer *tapRight = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapNext)];
    UITapGestureRecognizer *tapLeft = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapPrev)];
    UIView *rightZone = [[UIView alloc] initWithFrame:CGRectMake(self.view.bounds.size.width / 2, 0, self.view.bounds.size.width / 2, self.view.bounds.size.height)];
    rightZone.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleLeftMargin;
    [rightZone addGestureRecognizer:tapRight];
    [self.view insertSubview:rightZone aboveSubview:_imageView];

    UIView *leftZone = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width / 2, self.view.bounds.size.height)];
    leftZone.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [leftZone addGestureRecognizer:tapLeft];
    [self.view insertSubview:leftZone aboveSubview:_imageView];

    UISwipeGestureRecognizer *swipeDown = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(closeTapped)];
    swipeDown.direction = UISwipeGestureRecognizerDirectionDown;
    [self.view addGestureRecognizer:swipeDown];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(self.view.bounds.size.width - 52, top + 2, 44, 44);
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.titleLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.7];
    close.titleLabel.shadowOffset = CGSizeMake(0, 1);
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    _spinner.center = CGPointMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2);
    _spinner.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    _spinner.hidesWhenStopped = YES;
    [self.view addSubview:_spinner];

    [self showCurrentItem];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [_timer invalidate];
    [_player stop];
    [_fetchTask cancel];
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

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_timer invalidate];
    [_fetchTask cancel];
    [[SHImageLoader shared] cancelToken:_imageToken];
}

// The tray carries the items of its first reels only. A reel reached without them is fetched here, into the
// tray's own object, so the next opening is instant; one that has nothing to show (expired) is skipped.
- (void)fetchCurrentReel:(SHStoryReel *)reel
{
    NSUInteger serial = ++_showSerial;
    _imageView.image = nil;
    _usernameLabel.text = reel.user.username;
    _timeLabel.text = @"";
    _progressFill.frame = CGRectMake(0, 0, 0, 2);
    [_spinner startAnimating];
    [_fetchTask cancel];
    _fetchTask = [SHInstagram storiesForUserIds:@[ reel.user.pk ?: @"" ] completion:^(NSArray *reels, NSError *error) {
        if (serial != self->_showSerial) return;
        SHStoryReel *fetched = [reels firstObject];
        if (fetched.items.count) {
            reel.items = fetched.items;
            [self showCurrentItem];
            return;
        }
        [self->_spinner stopAnimating];
        if (self->_reelIndex + 1 < self->_reels.count) {
            self->_reelIndex++;
            self->_itemIndex = 0;
            [self showCurrentItem];
        } else {
            if (error) [SHUtils alertWithTitle:L(@"Stories") message:error.localizedDescription];
            [self closeTapped];
        }
    }];
}

- (void)showCurrentItem
{
    [_timer invalidate];
    _timer = nil;
    if (_player) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:nil object:_player];
        [_player stop];
        [_player.view removeFromSuperview];
    }
    _player = nil;

    SHStoryReel *reel = [self currentReel];
    if (!reel) { [self closeTapped]; return; }
    if (!reel.items.count) { [self fetchCurrentReel:reel]; return; }
    SHStoryItem *item = [self currentItem];
    if (!item) { [self advanceItem]; return; }
    if ([[NSFileManager defaultManager] fileExistsAtPath:[[SHUtils documentsPath] stringByAppendingPathComponent:@"debug"]])
        SHLog(@"Story: reel %lu/%lu item %lu/%lu type=%ld", (unsigned long)_reelIndex + 1, (unsigned long)_reels.count,
              (unsigned long)_itemIndex + 1, (unsigned long)reel.items.count, (long)item.mediaType);

    _usernameLabel.text = reel.user.username;
    _timeLabel.text = item.takenAt ? [SHUtils formatRelativeDate:item.takenAt] : @"";
    _progressFill.frame = CGRectMake(0, 0, 0, 2);

    [[SHImageLoader shared] cancelToken:_imageToken];
    _imageToken = nil;
    NSUInteger serial = ++_showSerial;

    if (item.mediaType == 2 && item.videoURL.length) {
        _imageView.image = nil;
        [_spinner startAnimating];
        NSString *proxied = [[SHMediaProxy shared] proxyURLForURL:[NSURL URLWithString:item.videoURL]];
        _player = [[MPMoviePlayerController alloc] initWithContentURL:[NSURL URLWithString:proxied]];
        _player.view.frame = self.view.bounds;
        _player.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _player.controlStyle = MPMovieControlStyleNone;
        _player.shouldAutoplay = YES;
        [self.view insertSubview:_player.view aboveSubview:_imageView];
        // the clock starts once the video actually plays, not while it buffers
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackStateChanged:)
                                                     name:MPMoviePlayerPlaybackStateDidChangeNotification object:_player];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackFinished:)
                                                     name:MPMoviePlayerPlaybackDidFinishNotification object:_player];
    } else {
        _imageView.image = nil;
        [_spinner startAnimating];
        _imageToken = [[SHImageLoader shared] loadImage:item.image.url maxPixels:1024 completion:^(UIImage *image) {
            if (serial != self->_showSerial) return;   // moved on already
            [self->_spinner stopAnimating];
            if (!image) { [self advanceItem]; return; }   // nothing to look at for five seconds: move on
            self->_imageView.image = image;
            [self startTimerWithDuration:SHStoryDuration];
        }];
        if (_imageView.image) { [_spinner stopAnimating]; [self startTimerWithDuration:SHStoryDuration]; }   // was cached
    }
}

- (void)playbackStateChanged:(NSNotification *)note
{
    if (_player.playbackState == MPMoviePlaybackStatePlaying && !_timer) {
        [_spinner stopAnimating];
        SHStoryItem *item = [self currentItem];
        NSTimeInterval dur = _player.duration > 0 ? _player.duration : (item.videoDuration > 0 ? item.videoDuration : 15);
        [self startTimerWithDuration:dur];
    }
}

- (void)playbackFinished:(NSNotification *)note { [self advanceItem]; }

- (void)startTimerWithDuration:(NSTimeInterval)duration
{
    [_timer invalidate];
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(timerTick:) userInfo:@(duration) repeats:YES];
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

- (UIStatusBarStyle)preferredStatusBarStyle { return (UIStatusBarStyle)1; }
- (BOOL)prefersStatusBarHidden { return YES; }

@end
