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
static const CGFloat SHStoryTop = 30;        // the progress bars
static const CGFloat SHStoryAvatar = 34;

@interface SHStoryViewController ()
@property (nonatomic, strong) NSArray *reels;
@property (nonatomic) NSUInteger reelIndex;
@property (nonatomic) NSUInteger startIndex;   // the circle that was tapped
@property (nonatomic) NSUInteger itemIndex;
@property (nonatomic, strong) SHImageView *imageView;
@property (nonatomic, strong) MPMoviePlayerController *player;
@property (nonatomic, strong) SHImageView *avatarView;
@property (nonatomic, strong) UILabel *usernameLabel;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UIButton *profileButton;
@property (nonatomic, strong) UIView *progressContainer;
@property (nonatomic, strong) NSMutableArray *segmentTracks;   // one bar per story of the reel
@property (nonatomic, strong) NSMutableArray *segmentFills;
@property (nonatomic, weak) SHStoryReel *segmentsReel;
@property (nonatomic) CGFloat segmentsWidth;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) CFAbsoluteTime itemStart;
@property (nonatomic) NSTimeInterval itemDuration;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) id imageToken;
@property (nonatomic) NSUInteger showSerial;
@property (nonatomic, strong) SHHTTPTask *fetchTask;   // the items of a tray reel that came without them
@property (nonatomic, strong) NSMutableArray *pendingSeen;   // stories of the current reel seen, not told to Instagram yet
@property (nonatomic, weak) SHStoryReel *pendingReel;
@property (nonatomic) BOOL closing;
@end

@implementation SHStoryViewController

- (instancetype)initWithReels:(NSArray *)reels startIndex:(NSUInteger)index
{
    if ((self = [super init])) {
        _reels = reels;
        _reelIndex = index;
        _startIndex = index;
        SHStoryReel *reel = index < reels.count ? reels[index] : nil;
        _itemIndex = [reel firstUnseenIndex];   // where the viewer left off last time
        _pendingSeen = [NSMutableArray array];
        _segmentTracks = [NSMutableArray array];
        _segmentFills = [NSMutableArray array];
    }
    return self;
}

- (UILabel *)shadowLabel:(UIFont *)font color:(UIColor *)color
{
    UILabel *l = [[UILabel alloc] init];
    l.font = font;
    l.textColor = color;
    l.backgroundColor = [UIColor clearColor];
    l.shadowColor = [UIColor colorWithWhite:0 alpha:0.7];
    l.shadowOffset = CGSizeMake(0, 1);
    [self.view addSubview:l];
    return l;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    CGFloat w = self.view.bounds.size.width;

    _imageView = [[SHImageView alloc] initWithFrame:self.view.bounds];
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_imageView];

    // a dark fade behind the bars and the name, so they read on a bright picture
    UIImageView *shade = [[UIImageView alloc] initWithImage:[[SHTheme shared] controlsGradientImageTop:YES]];
    shade.frame = CGRectMake(0, 0, w, 120);
    shade.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:shade];

    _progressContainer = [[UIView alloc] initWithFrame:CGRectMake(8, SHStoryTop, w - 16, 3)];
    _progressContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _progressContainer.backgroundColor = [UIColor clearColor];
    [self.view addSubview:_progressContainer];

    _avatarView = [[SHImageView alloc] initWithFrame:CGRectMake(12, SHStoryTop + 12, SHStoryAvatar, SHStoryAvatar)];
    _avatarView.layer.cornerRadius = SHStoryAvatar / 2;
    _avatarView.layer.masksToBounds = YES;
    _avatarView.layer.borderWidth = 1.5;
    _avatarView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.9].CGColor;
    _avatarView.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1];
    _avatarView.maxPixels = 96;
    [self.view addSubview:_avatarView];
    _usernameLabel = [self shadowLabel:[UIFont boldSystemFontOfSize:15] color:[UIColor whiteColor]];
    _timeLabel = [self shadowLabel:[UIFont boldSystemFontOfSize:12] color:[UIColor colorWithWhite:1 alpha:0.7]];

    // Tap zones go UNDER the controls (otherwise the close button is unreachable); a swipe down also closes.
    UITapGestureRecognizer *tapRight = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapNext)];
    UITapGestureRecognizer *tapLeft = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapPrev)];
    UIView *rightZone = [[UIView alloc] initWithFrame:CGRectMake(w / 2, 0, w / 2, self.view.bounds.size.height)];
    rightZone.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleLeftMargin;
    [rightZone addGestureRecognizer:tapRight];
    [self.view insertSubview:rightZone aboveSubview:_imageView];

    UIView *leftZone = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w / 2, self.view.bounds.size.height)];
    leftZone.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [leftZone addGestureRecognizer:tapLeft];
    [self.view insertSubview:leftZone aboveSubview:_imageView];

    UISwipeGestureRecognizer *swipeDown = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(closeTapped)];
    swipeDown.direction = UISwipeGestureRecognizerDirectionDown;
    [self.view addGestureRecognizer:swipeDown];

    // the picture and the name open the person's profile
    _profileButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [_profileButton addTarget:self action:@selector(profileTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_profileButton];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(w - 52, SHStoryTop + 7, 44, 44);
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [close setImage:[[SHTheme shared] closeIconWhite] forState:UIControlStateNormal];   // drawn, not a character
    close.accessibilityLabel = L(@"Done");
    close.layer.shadowColor = [UIColor blackColor].CGColor;
    close.layer.shadowOpacity = 0.7;
    close.layer.shadowRadius = 1.5;
    close.layer.shadowOffset = CGSizeMake(0, 1);
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    _spinner.center = CGPointMake(w / 2, self.view.bounds.size.height / 2);
    _spinner.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    _spinner.hidesWhenStopped = YES;
    [self.view addSubview:_spinner];

    [self showCurrentItem];
}

- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    // (turned on its side: the bars are laid out again for the new width)
    if (_segmentsReel && fabs(_progressContainer.bounds.size.width - _segmentsWidth) > 0.5) {
        [self buildSegmentsForReel:_segmentsReel];
        [self updateSegmentsWithProgress:_itemDuration > 0 ? (CFAbsoluteTimeGetCurrent() - _itemStart) / _itemDuration : 0];
    }
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [_timer invalidate];
    [_player stop];
    [_fetchTask cancel];
    [self flushSeen];
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

#pragma mark - The person at the top

- (void)showHeaderForReel:(SHStoryReel *)reel item:(SHStoryItem *)item
{
    [_avatarView setImageURL:reel.user.profilePicURL placeholder:[[SHTheme shared] avatarPlaceholderWithSize:SHStoryAvatar]];
    _usernameLabel.text = reel.user.username;
    _timeLabel.text = item.takenAt ? [SHUtils formatRelativeDate:item.takenAt] : @"";
    CGFloat x = 12 + SHStoryAvatar + 10, y = SHStoryTop + 12;
    CGFloat maxName = self.view.bounds.size.width - x - 140;
    CGFloat nameW = MIN(maxName, [_usernameLabel.text sizeWithFont:_usernameLabel.font].width);
    _usernameLabel.frame = CGRectMake(x, y, nameW, SHStoryAvatar);
    CGFloat timeW = [_timeLabel.text sizeWithFont:_timeLabel.font].width;
    _timeLabel.frame = CGRectMake(x + nameW + 8, y + 1, timeW, SHStoryAvatar);
    _profileButton.frame = CGRectMake(6, y - 6, x + nameW + 6, SHStoryAvatar + 12);
    _profileButton.accessibilityLabel = reel.user.username;
}

- (void)profileTapped
{
    SHUser *user = [self currentReel].user;
    if (!user.username.length && !user.pk.length) return;
    void (^open)(SHUser *) = self.onOpenProfile;
    [self closeThen:^{ if (open) open(user); }];
}

#pragma mark - Progress bars (one per story of the reel)

- (void)buildSegmentsForReel:(SHStoryReel *)reel
{
    for (UIView *v in _segmentTracks) [v removeFromSuperview];
    [_segmentTracks removeAllObjects];
    [_segmentFills removeAllObjects];
    NSUInteger n = MAX((NSUInteger)1, reel.items.count);
    CGFloat w = _progressContainer.bounds.size.width, gap = 4;
    CGFloat segW = floorf((w - gap * (n - 1)) / n);
    for (NSUInteger i = 0; i < n; i++) {
        UIView *track = [[UIView alloc] initWithFrame:CGRectMake(i * (segW + gap), 0, segW, 3)];
        track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.35];
        track.layer.cornerRadius = 1.5;
        track.clipsToBounds = YES;
        UIView *fill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 3)];
        fill.backgroundColor = [UIColor whiteColor];
        [track addSubview:fill];
        [_progressContainer addSubview:track];
        [_segmentTracks addObject:track];
        [_segmentFills addObject:fill];
    }
    _segmentsReel = reel;
    _segmentsWidth = w;
}

// the stories before the current one full, the current one as far as it got, the rest empty
- (void)updateSegmentsWithProgress:(CGFloat)progress
{
    CGFloat p = MAX(0, MIN(1, progress));
    for (NSUInteger i = 0; i < _segmentFills.count; i++) {
        UIView *fill = _segmentFills[i];
        CGFloat full = [_segmentTracks[i] bounds].size.width;
        CGFloat width = i < _itemIndex ? full : (i == _itemIndex ? floorf(full * p) : 0);
        fill.frame = CGRectMake(0, 0, width, 3);
    }
}

#pragma mark - Seen

// The story is on screen: it counts as seen (the ring, where the reel starts next time, and Instagram's view list).
- (void)itemShown:(SHStoryItem *)item ofReel:(SHStoryReel *)reel
{
    if (!item) return;
    if (_pendingReel != reel) [self flushSeen];
    BOOL isNew = [item.takenAt timeIntervalSince1970] > reel.seenUpTo;
    [reel noteSeenItem:item];
    if (!isNew) return;   // watched again: Instagram knows already, no request for it
    _pendingReel = reel;
    if (![_pendingSeen containsObject:item]) [_pendingSeen addObject:item];
}

// Tells Instagram about the stories seen of the reel just left (one request per person).
- (void)flushSeen
{
    SHStoryReel *reel = _pendingReel;
    if (reel && _pendingSeen.count) [SHInstagram markStoryItems:[_pendingSeen copy] ofReel:reel completion:nil];
    [_pendingSeen removeAllObjects];
    _pendingReel = nil;
}

#pragma mark - Showing

// The tray carries the items of its first reels only. A reel reached without them is fetched here, into the
// tray's own object, so the next opening is instant; one that has nothing to show (expired) is skipped.
- (void)fetchCurrentReel:(SHStoryReel *)reel
{
    NSUInteger serial = ++_showSerial;
    _imageView.image = nil;
    [self showHeaderForReel:reel item:nil];
    [self buildSegmentsForReel:reel];
    [self updateSegmentsWithProgress:0];
    [_spinner startAnimating];
    [_fetchTask cancel];
    _fetchTask = [SHInstagram storiesForUserIds:@[ reel.user.pk ?: @"" ] completion:^(NSArray *reels, NSError *error) {
        if (serial != self->_showSerial) return;
        SHStoryReel *fetched = [reels firstObject];
        if (fetched.items.count) {
            reel.items = fetched.items;
            self->_itemIndex = [reel firstUnseenIndex];
            [self showCurrentItem];
            return;
        }
        // Nothing to show: the viewer closes rather than racing through the rest of the tray with a request per
        // reel (a burst Instagram would notice); the user picks the next circle. The reel that was tapped says why.
        [self->_spinner stopAnimating];
        if (self->_reelIndex == self->_startIndex)
            [SHUtils alertWithTitle:L(@"Stories") message:error.localizedDescription ?: L(@"This story is no longer available.")];
        [self closeTapped];
    }];
}

- (void)showCurrentItem
{
    [_timer invalidate];
    _timer = nil;
    _itemDuration = 0;
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

    [self showHeaderForReel:reel item:item];
    if (_segmentsReel != reel || _segmentTracks.count != MAX((NSUInteger)1, reel.items.count)) [self buildSegmentsForReel:reel];
    [self updateSegmentsWithProgress:0];

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
        // (shouldAutoplay alone does not start the loading: without these the spinner turned forever)
        [_player prepareToPlay];
        [_player play];
    } else {
        _imageView.image = nil;
        [_spinner startAnimating];
        // (a picture already in memory answers at once, inside this call)
        _imageToken = [[SHImageLoader shared] loadImage:item.image.url maxPixels:1024 completion:^(UIImage *image) {
            if (serial != self->_showSerial) return;   // moved on already
            [self->_spinner stopAnimating];
            if (!image) { [self advanceItem]; return; }   // nothing to look at for five seconds: move on
            self->_imageView.image = image;
            [self itemShown:item ofReel:reel];
            [self startTimerWithDuration:SHStoryDuration];
        }];
    }
}

- (void)playbackStateChanged:(NSNotification *)note
{
    if (_player.playbackState == MPMoviePlaybackStatePlaying && !_timer) {
        [_spinner stopAnimating];
        SHStoryItem *item = [self currentItem];
        [self itemShown:item ofReel:[self currentReel]];
        NSTimeInterval dur = _player.duration > 0 ? _player.duration : (item.videoDuration > 0 ? item.videoDuration : 15);
        [self startTimerWithDuration:dur];
    }
}

- (void)playbackFinished:(NSNotification *)note { [self advanceItem]; }

- (void)startTimerWithDuration:(NSTimeInterval)duration
{
    [_timer invalidate];
    _itemStart = CFAbsoluteTimeGetCurrent();
    _itemDuration = MAX(0.5, duration);
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(timerTick:) userInfo:nil repeats:YES];
}

- (void)timerTick:(NSTimer *)t
{
    CGFloat progress = (CFAbsoluteTimeGetCurrent() - _itemStart) / _itemDuration;
    [self updateSegmentsWithProgress:progress];
    if (progress >= 1) [self advanceItem];
}

- (void)advanceItem
{
    SHStoryReel *reel = [self currentReel];
    if (reel && _itemIndex + 1 < reel.items.count) {
        _itemIndex++;
    } else if (_reelIndex + 1 < _reels.count) {
        [self flushSeen];
        _reelIndex++;
        _itemIndex = [[self currentReel] firstUnseenIndex];   // the next person's from where it was left off
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
        [self flushSeen];
        _reelIndex--;
        SHStoryReel *reel = [self currentReel];
        _itemIndex = reel.items.count > 0 ? reel.items.count - 1 : 0;
    }
    [self showCurrentItem];
}

- (void)closeTapped { [self closeThen:nil]; }

// Closes the viewer (once), tells Instagram what was seen, and then runs `then` and the owner's onClose.
- (void)closeThen:(void (^)(void))then
{
    if (_closing) return;
    _closing = YES;
    [_timer invalidate];
    [_player stop];
    [self flushSeen];
    void (^onClose)(void) = self.onClose;
    [self dismissViewControllerAnimated:YES completion:^{
        if (then) then();
        if (onClose) onClose();
    }];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

- (UIStatusBarStyle)preferredStatusBarStyle { return (UIStatusBarStyle)1; }
- (BOOL)prefersStatusBarHidden { return YES; }

@end
