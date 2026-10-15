#import "SHThreadViewController.h"
#import "SHProfileViewController.h"
#import "SHPostDetailViewController.h"
#import "SHTabIcons.h"
#import "SHInstagram.h"
#import "SHModels.h"
#import "SHSettings.h"
#import "SHImageLoader.h"
#import "SHMediaProxy.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHLinkRouter.h"
#import "SHLinkLabel.h"
#import "SHShareViewController.h"
#import "SHCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>

static NSString * const SHMsgCellId = @"MsgCell";

// Bubble geometry
static const CGFloat SHBubbleMaxFrac = 0.70;   // of the table width
static const CGFloat SHBubbleFont    = 15.0;
static const CGFloat SHBubblePadX    = 12.0;
static const CGFloat SHBubblePadY    = 7.0;
static const CGFloat SHAvatarSize    = 30.0;
static const CGFloat SHMediaSide     = 200.0;
static const CGFloat SHVoiceW        = 230.0;
static const CGFloat SHVoiceH        = 44.0;
static const CGFloat SHLikeSide      = 40.0;
static const CGFloat SHTimeH         = 14.0;
static const CGFloat SHRowGap        = 5.0;
static const CGFloat SHEdge          = 8.0;
static const CGFloat SHBarH          = 48.0;

#pragma mark - Bubble cell

@class SHBubbleCell;
@protocol SHBubbleCellDelegate <NSObject>
- (void)bubbleCell:(SHBubbleCell *)cell didTapAvatarOfUser:(SHUser *)user;
- (void)bubbleCell:(SHBubbleCell *)cell didTapMessage:(SHDirectMessage *)message;
@end

// One message the way iOS 6 Messages drew them: glossy bubbles with a tail (blue for mine), the sender's picture by
// the last bubble of a run, the time under it. A voice message has a round play button and a groove that fills as
// it plays; a heart sent on its own is shown as a heart.
@interface SHBubbleCell : UITableViewCell
@property (nonatomic, weak) id<SHBubbleCellDelegate> delegate;
@property (nonatomic, strong) SHDirectMessage *message;
@property (nonatomic, strong) SHUser *sender;
@property (nonatomic, strong) SHImageView *avatar;
@property (nonatomic, strong) UIImageView *bubble;
@property (nonatomic, strong) UITapGestureRecognizer *bubbleTap;
@property (nonatomic, strong) SHLinkLabel *textLabel2;
@property (nonatomic, strong) SHImageView *media;
@property (nonatomic, strong) UIImageView *playBadge;
@property (nonatomic, strong) UILabel *captionLabel;   // "@user" under a shared post
@property (nonatomic, strong) UIButton *voiceButton;
@property (nonatomic, strong) UILabel *voiceLabel;
@property (nonatomic, strong) UIImageView *voiceTrack;
@property (nonatomic, strong) UIImageView *voiceFill;
@property (nonatomic, strong) UIImageView *heartView;
@property (nonatomic, strong) UILabel *timeLabel;
+ (CGFloat)heightForMessage:(SHDirectMessage *)m width:(CGFloat)width;
- (void)configureWithMessage:(SHDirectMessage *)m outgoing:(BOOL)outgoing sender:(SHUser *)sender showAvatar:(BOOL)showAvatar
                       width:(CGFloat)width playing:(BOOL)playing progress:(CGFloat)progress timeText:(NSString *)timeText;
- (void)setVoiceProgress:(CGFloat)progress;
@end

@implementation SHBubbleCell

static BOOL SHIsLike(SHDirectMessage *m) { return [m.type isEqualToString:@"like"]; }

// What a text bubble says (a label in italics for what has no text of its own); the same measures and draws.
static NSAttributedString *SHBubbleText(SHDirectMessage *m)
{
    BOOL placeholder = m.text.length == 0;
    NSString *s = [SHUtils displayText:placeholder ? (m.placeholderText ?: @"") : m.text];
    UIFont *font = placeholder ? [UIFont italicSystemFontOfSize:SHBubbleFont] : [UIFont systemFontOfSize:SHBubbleFont];
    return [[NSAttributedString alloc] initWithString:s.length ? s : @" " attributes:@{ NSFontAttributeName: font }];
}

// The size of the bubble for a message, given the table width.
+ (CGSize)bubbleSizeForMessage:(SHDirectMessage *)m width:(CGFloat)width
{
    CGFloat tail = [[SHTheme shared] bubbleTailWidth];
    if (SHIsLike(m)) return CGSizeMake(SHLikeSide, SHLikeSide);
    if (m.audioURL.length) return CGSizeMake(SHVoiceW, SHVoiceH);
    if (m.previewURL.length || m.localImage) return CGSizeMake(SHMediaSide, SHMediaSide + ((m.sharedPost || m.shareTitle.length) ? 20 : 0));
    CGFloat maxw = floorf(width * SHBubbleMaxFrac) - SHBubblePadX * 2 - tail;
    CGSize sz = [SHLinkLabel sizeForAttributedText:SHBubbleText(m) width:maxw lines:0];
    // (never below the caps of the bubble artwork: 30 points high, 36 wide)
    return CGSizeMake(MAX(ceilf(sz.width), 12) + SHBubblePadX * 2 + tail, MAX(ceilf(sz.height), 19) + SHBubblePadY * 2);
}

+ (CGFloat)heightForMessage:(SHDirectMessage *)m width:(CGFloat)width
{
    return SHRowGap + [self bubbleSizeForMessage:m width:width].height + 2 + SHTimeH + SHRowGap;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        SHTheme *theme = [SHTheme shared];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];

        _avatar = [[SHImageView alloc] initWithFrame:CGRectMake(SHEdge, 0, SHAvatarSize, SHAvatarSize)];
        [theme styleAvatar:_avatar radius:4];
        _avatar.maxPixels = 96;
        _avatar.userInteractionEnabled = YES;
        [_avatar addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(avatarTapped)]];
        [self.contentView addSubview:_avatar];

        _bubble = [[UIImageView alloc] initWithFrame:CGRectZero];
        _bubble.userInteractionEnabled = YES;
        _bubbleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bubbleTapped)];
        [_bubble addGestureRecognizer:_bubbleTap];
        [self.contentView addSubview:_bubble];

        // a text's @names, #tags and links open on a tap
        _textLabel2 = [[SHLinkLabel alloc] initWithFrame:CGRectZero];
        _textLabel2.font = [UIFont systemFontOfSize:SHBubbleFont];
        [_bubble addSubview:_textLabel2];

        _media = [[SHImageView alloc] initWithFrame:CGRectZero];
        _media.contentMode = UIViewContentModeScaleAspectFill;
        _media.clipsToBounds = YES;
        _media.maxPixels = 400;
        _media.backgroundColor = theme.isDark ? [UIColor colorWithWhite:0.12 alpha:1] : [UIColor colorWithWhite:0.85 alpha:1];
        [_bubble addSubview:_media];

        _playBadge = [[UIImageView alloc] initWithImage:[theme playButtonImageWithSize:44]];
        [_bubble addSubview:_playBadge];

        _captionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _captionLabel.font = [UIFont boldSystemFontOfSize:12];
        _captionLabel.backgroundColor = [UIColor clearColor];
        _captionLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.6];
        _captionLabel.shadowOffset = CGSizeMake(0, -1);
        [_bubble addSubview:_captionLabel];

        _voiceButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _voiceButton.adjustsImageWhenHighlighted = YES;
        [_voiceButton addTarget:self action:@selector(bubbleTapped) forControlEvents:UIControlEventTouchUpInside];
        [_bubble addSubview:_voiceButton];

        _voiceTrack = [[UIImageView alloc] initWithImage:[theme voiceTrackImageFilled:NO]];
        [_bubble addSubview:_voiceTrack];
        _voiceFill = [[UIImageView alloc] initWithImage:[theme voiceTrackImageFilled:YES]];
        [_bubble addSubview:_voiceFill];

        _voiceLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _voiceLabel.font = [UIFont boldSystemFontOfSize:12];
        _voiceLabel.backgroundColor = [UIColor clearColor];
        _voiceLabel.textAlignment = NSTextAlignmentRight;
        [_bubble addSubview:_voiceLabel];

        _heartView = [[UIImageView alloc] initWithFrame:CGRectZero];
        [_bubble addSubview:_heartView];

        _timeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _timeLabel.font = [UIFont boldSystemFontOfSize:10];
        _timeLabel.textColor = [theme secondaryTextColor];
        _timeLabel.backgroundColor = [UIColor clearColor];
        [theme embossLabel:_timeLabel];
        [self.contentView addSubview:_timeLabel];
    }
    return self;
}

- (void)avatarTapped { if (_sender) [self.delegate bubbleCell:self didTapAvatarOfUser:_sender]; }
- (void)bubbleTapped { if (_message) [self.delegate bubbleCell:self didTapMessage:_message]; }

- (void)setVoiceProgress:(CGFloat)progress
{
    CGRect track = _voiceTrack.frame;
    CGFloat p = MAX(0, MIN(1, progress));
    _voiceFill.hidden = _voiceTrack.hidden || p <= 0;
    _voiceFill.frame = CGRectMake(track.origin.x, track.origin.y, MAX(6, floorf(track.size.width * p)), track.size.height);
}

- (void)configureWithMessage:(SHDirectMessage *)m outgoing:(BOOL)outgoing sender:(SHUser *)sender showAvatar:(BOOL)showAvatar
                       width:(CGFloat)width playing:(BOOL)playing progress:(CGFloat)progress timeText:(NSString *)timeText
{
    _message = m;
    _sender = sender;
    SHTheme *theme = [SHTheme shared];
    BOOL isLike = SHIsLike(m);
    BOOL isVoice = !isLike && m.audioURL.length > 0;
    BOOL isMedia = !isLike && !isVoice && (m.previewURL.length > 0 || m.localImage);
    // a text's own label takes the taps on its links; the bubble's tap is for voice, pictures and shared posts
    _bubbleTap.enabled = isVoice || isMedia;
    self.contentView.alpha = m.sending ? 0.55f : 1;
    CGFloat tail = [theme bubbleTailWidth];
    CGFloat inset = outgoing ? 0 : tail;   // the tail side of a bubble is not room for its content
    UIColor *fg = (outgoing || theme.isDark) ? [UIColor whiteColor] : [theme textColor];
    UIColor *shadow = (outgoing || theme.isDark) ? [UIColor colorWithWhite:0 alpha:outgoing ? 0.35 : 0.6] : [UIColor colorWithWhite:1 alpha:0.8];
    CGSize shadowOffset = (outgoing || theme.isDark) ? CGSizeMake(0, -1) : CGSizeMake(0, 1);

    CGSize bsz = [SHBubbleCell bubbleSizeForMessage:m width:width];
    // incoming bubbles always leave room for the picture, so that a run of them lines up
    CGFloat x = outgoing ? width - SHEdge - bsz.width : SHEdge + SHAvatarSize + 6;
    _bubble.frame = CGRectMake(x, SHRowGap, bsz.width, bsz.height);
    if (isMedia) {
        _bubble.image = nil;
        _bubble.layer.cornerRadius = 12;
        _bubble.layer.masksToBounds = YES;
        _bubble.layer.borderWidth = 1;
        _bubble.layer.borderColor = [UIColor colorWithWhite:0 alpha:theme.isDark ? 0.85 : 0.3].CGColor;
        _bubble.backgroundColor = outgoing ? [SHUtils colorFromHex:@"#1C6FD8"] : (theme.isDark ? [UIColor colorWithWhite:0.22 alpha:1] : [UIColor colorWithWhite:0.88 alpha:1]);
    } else {
        _bubble.image = isLike ? nil : [theme bubbleImageOutgoing:outgoing];
        _bubble.layer.cornerRadius = 0;
        _bubble.layer.masksToBounds = NO;
        _bubble.layer.borderWidth = 0;
        _bubble.backgroundColor = [UIColor clearColor];
    }

    _avatar.hidden = outgoing || !showAvatar;
    if (!_avatar.hidden) {
        _avatar.frame = CGRectMake(SHEdge, SHRowGap + bsz.height - SHAvatarSize, SHAvatarSize, SHAvatarSize);
        [_avatar setImageURL:sender.profilePicURL placeholder:[theme avatarPlaceholderWithSize:SHAvatarSize]];
    }

    _textLabel2.hidden = isVoice || isMedia || isLike;
    _media.hidden = !isMedia;
    _playBadge.hidden = !(isMedia && (m.videoURL.length || m.sharedPost.videoURL.length || m.sharedPost.mediaType == 2
                                      || [m.type isEqualToString:@"xma_clip"]));
    _captionLabel.hidden = !(isMedia && (m.sharedPost || m.shareTitle.length));
    _voiceButton.hidden = _voiceTrack.hidden = _voiceLabel.hidden = !isVoice;
    _voiceFill.hidden = YES;
    _heartView.hidden = !isLike;

    if (isLike) {
        [_media setImageURL:nil placeholder:nil];
        _heartView.image = [SHTabIcons heartWithSize:30 filled:YES color:[UIColor colorWithRed:0.93 green:0.2 blue:0.27 alpha:1] dark:theme.isDark];
        _heartView.frame = CGRectMake(floorf((bsz.width - _heartView.image.size.width) / 2), floorf((bsz.height - _heartView.image.size.height) / 2),
                                      _heartView.image.size.width, _heartView.image.size.height);
    } else if (isVoice) {
        [_media setImageURL:nil placeholder:nil];
        [_voiceButton setImage:[theme voiceButtonImagePlaying:playing] forState:UIControlStateNormal];
        _voiceButton.frame = CGRectMake(inset + 6, floorf((SHVoiceH - 32) / 2), 32, 32);
        CGFloat trackX = CGRectGetMaxX(_voiceButton.frame) + 10;
        CGFloat labelW = 40;
        CGFloat trackW = bsz.width - (outgoing ? tail : 0) - trackX - labelW - 14;
        _voiceTrack.frame = CGRectMake(trackX, floorf(SHVoiceH / 2) - 3, trackW, 6);
        _voiceLabel.frame = CGRectMake(trackX + trackW + 6, 0, labelW, SHVoiceH);
        _voiceLabel.textColor = fg;
        _voiceLabel.shadowColor = shadow;
        _voiceLabel.shadowOffset = shadowOffset;
        _voiceLabel.text = m.audioDuration > 0 ? [SHUtils formatDuration:m.audioDuration] : L(@"Voice");
        [self setVoiceProgress:playing ? progress : 0];
    } else if (isMedia) {
        _media.frame = CGRectMake(0, 0, SHMediaSide, SHMediaSide);
        if (m.localImage) {   // a photo just sent from here
            [_media setImageURL:nil placeholder:nil];
            _media.image = m.localImage;
        } else {
            [_media setImageURL:m.previewURL placeholder:nil];
        }
        _playBadge.frame = CGRectMake(SHMediaSide / 2 - 22, SHMediaSide / 2 - 22, 44, 44);
        if (m.sharedPost || m.shareTitle.length) {
            NSString *owner = m.sharedPost.user.username.length ? m.sharedPost.user.username : m.shareTitle;
            _captionLabel.frame = CGRectMake(8, SHMediaSide, SHMediaSide - 16, 20);
            _captionLabel.textColor = [UIColor whiteColor];
            _captionLabel.text = owner.length ? [@"@" stringByAppendingString:owner] : L(@"Shared a post");
        }
    } else {
        [_media setImageURL:nil placeholder:nil];
        BOOL placeholder = m.text.length == 0;
        _textLabel2.textColor = placeholder ? [fg colorWithAlphaComponent:0.75] : fg;
        // links stand out from the text: light on a blue or dark bubble, the link blue on a light one
        _textLabel2.linkColor = (outgoing || theme.isDark) ? [UIColor colorWithRed:0.78 green:0.9 blue:1 alpha:1] : [theme linkColor];
        _textLabel2.shadowColor = shadow;
        _textLabel2.shadowOffset = shadowOffset;
        _textLabel2.attributedText = SHBubbleText(m);
        _textLabel2.frame = CGRectMake(inset + SHBubblePadX, SHBubblePadY, bsz.width - SHBubblePadX * 2 - tail, bsz.height - SHBubblePadY * 2);
    }

    _timeLabel.text = timeText ?: @"";
    _timeLabel.textAlignment = outgoing ? NSTextAlignmentRight : NSTextAlignmentLeft;
    _timeLabel.frame = outgoing ? CGRectMake(x - 60, SHRowGap + bsz.height + 2, bsz.width + 60 - tail - 4, SHTimeH)
                                : CGRectMake(x + tail + 4, SHRowGap + bsz.height + 2, bsz.width + 60, SHTimeH);
}

@end

#pragma mark - Voice recorder

// A voice message being recorded: AAC in an MP4 file (what Instagram takes), at most a minute, with the level of
// the sound ten times a second (the waveform the chat draws).
@interface SHVoiceRecorder : NSObject <AVAudioRecorderDelegate>
@property (nonatomic, copy) void (^onTick)(NSTimeInterval seconds);
@property (nonatomic, copy) void (^onLimit)(void);   // the minute is full: recording stopped, ready to send
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readonly) NSArray *waveform;
@property (nonatomic, readonly) NSString *path;
@property (nonatomic, readonly) BOOL recording;
- (BOOL)start;
- (NSData *)finish;   // stops; the recording's bytes (nil when nothing usable was recorded)
- (void)cancel;
@end

@interface SHVoiceRecorder ()
@property (nonatomic, strong) AVAudioRecorder *recorder;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSMutableArray *levels;
@property (nonatomic, readwrite) NSTimeInterval duration;
@property (nonatomic, readwrite) NSString *path;
@property (nonatomic, readwrite) BOOL recording;
@property (nonatomic) BOOL stoppedHere;
@end

static const NSTimeInterval SHVoiceLimit = 60;

@implementation SHVoiceRecorder

- (NSArray *)waveform { return [_levels copy] ?: @[]; }

- (BOOL)start
{
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayAndRecord error:nil];
    [session setActive:YES error:nil];
    _path = [NSTemporaryDirectory() stringByAppendingPathComponent:
             [NSString stringWithFormat:@"voice-%lld.m4a", (long long)([NSDate timeIntervalSinceReferenceDate] * 1000)]];
    NSDictionary *settings = @{ AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @44100.0f, AVNumberOfChannelsKey: @1,
                                AVEncoderBitRateKey: @64000, AVEncoderAudioQualityKey: @(AVAudioQualityHigh) };
    NSError *error = nil;
    _recorder = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:_path] settings:settings error:&error];
    _recorder.delegate = self;
    _recorder.meteringEnabled = YES;
    if (!_recorder || ![_recorder prepareToRecord] || ![_recorder recordForDuration:SHVoiceLimit]) {
        SHLog(@"Voice: the recorder did not start: %@", error.localizedDescription ?: @"-");
        _recorder = nil;
        [self restoreSession];
        return NO;
    }
    _levels = [NSMutableArray array];
    _duration = 0;
    _recording = YES;
    _stoppedHere = NO;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    return YES;
}

- (void)tick
{
    if (!_recorder.isRecording) return;
    [_recorder updateMeters];
    float db = [_recorder averagePowerForChannel:0];                 // -160 … 0 dB
    float level = sqrtf(MAX(0.f, MIN(1.f, powf(10.f, db / 20.f))));  // loudness 0 … 1, the quiet parts still visible
    [_levels addObject:@(roundf(level * 1000.f) / 1000.f)];
    _duration = MAX(_duration, _recorder.currentTime);
    if (_onTick) _onTick(_duration);
}

- (void)restoreSession
{
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
}

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)recorder successfully:(BOOL)flag
{
    if (_stoppedHere) return;
    // the minute is full
    [_timer invalidate];
    _timer = nil;
    _recording = NO;
    _duration = MAX(_duration, SHVoiceLimit);
    [self restoreSession];
    if (_onLimit) _onLimit();
}

// (AVFoundation tells the recorder's delegate about a stop later, from the run loop, through an unretained
// reference: by then this object may be gone - the voice message crashed the app that way - so the delegate goes
// before every stop)
- (NSData *)finish
{
    _duration = MAX(_duration, _recorder.currentTime);
    _stoppedHere = YES;
    _recorder.delegate = nil;
    [_recorder stop];
    [_timer invalidate];
    _timer = nil;
    _recording = NO;
    [self restoreSession];
    if (_duration < 1) return nil;   // (a tap, not a message)
    NSData *data = [NSData dataWithContentsOfFile:_path];
    return data.length > 1000 ? data : nil;
}

- (void)cancel
{
    _stoppedHere = YES;
    _recorder.delegate = nil;
    [_recorder stop];
    [_recorder deleteRecording];
    [_timer invalidate];
    _timer = nil;
    _recording = NO;
    [self restoreSession];
}

- (void)dealloc
{
    [_timer invalidate];
    _recorder.delegate = nil;
    [_recorder stop];
}

@end

#pragma mark - Thread

static const CGFloat SHAttachH = 72;   // the strip with a picked photo above the bar

// A photo as it is sent: at most 1080 points on its longer side, turned upright (the camera's orientation applied).
static NSData *SHJPEGForSending(UIImage *image, UIImage **thumb)
{
    CGSize s = image.size;
    CGFloat longest = MAX(s.width, s.height);
    if (longest <= 0) return nil;
    CGFloat scale = longest > 1080 ? 1080 / longest : 1;
    CGSize target = CGSizeMake(floorf(s.width * scale), floorf(s.height * scale));
    UIGraphicsBeginImageContextWithOptions(target, YES, 1);
    [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
    UIImage *flat = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (thumb) *thumb = flat;
    return UIImageJPEGRepresentation(flat, 0.82f);
}

@interface SHThreadViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, SHBubbleCellDelegate,
                                      UIActionSheetDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) SHDirectThread *thread;
@property (nonatomic, strong) NSMutableArray *messages;      // chronological (oldest first)
@property (nonatomic, strong) NSMutableDictionary *usersByPk; // SHUser by pk, incl. me
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *inputBar;
@property (nonatomic, strong) UITextField *inputField;
@property (nonatomic, strong) UIButton *sendButton;
@property (nonatomic, strong) SHHTTPTask *task;
@property (nonatomic, copy) NSString *myId;
@property (nonatomic, copy) NSString *olderCursor;
@property (nonatomic) BOOL loadingOlder;
@property (nonatomic, strong) AVPlayer *voicePlayer;
@property (nonatomic, strong) id voiceTimeObserver;
@property (nonatomic) CGFloat voiceProgress;
@property (nonatomic, copy) NSString *playingPk;
@property (nonatomic, strong) NSDateFormatter *timeFormatter;
@property (nonatomic, strong) NSDateFormatter *dateFormatter;
@property (nonatomic, strong) UIButton *cameraButton;
@property (nonatomic, strong) UIButton *micButton;
@property (nonatomic, strong) UIView *recordView;          // over the field while a voice message is recorded
@property (nonatomic, strong) UILabel *recordLabel;
@property (nonatomic, strong) UIImageView *recordDot;
@property (nonatomic, strong) SHVoiceRecorder *recorder;
@property (nonatomic, strong) UIView *attachmentView;      // a picked photo waiting for Send, above the bar
@property (nonatomic, strong) UIImageView *attachmentThumb;
@property (nonatomic, strong) NSData *pendingJPEG;
@property (nonatomic, strong) UIImage *pendingImage;
@property (nonatomic, strong) UIPopoverController *pickerPopover;
@property (nonatomic, strong) UIActionSheet *photoSheet;     // "Take Photo / Choose Existing" while it is up
@property (nonatomic) CGFloat keyboardOverlap;
@end

@implementation SHThreadViewController

- (instancetype)initWithThread:(SHDirectThread *)thread
{
    if ((self = [super init])) {
        _thread = thread;
        _messages = [NSMutableArray array];
        _usersByPk = [NSMutableDictionary dictionary];
        _myId = [SHSettings userId];
        _timeFormatter = [[NSDateFormatter alloc] init];
        _timeFormatter.dateFormat = @"H:mm";
        _dateFormatter = [[NSDateFormatter alloc] init];
        _dateFormatter.dateFormat = @"d.M. H:mm";
        [self indexUsers:thread.users];
    }
    return self;
}

- (void)indexUsers:(NSArray *)users
{
    for (SHUser *u in users) if (u.pk.length) _usersByPk[u.pk] = u;
}

- (SHUser *)otherUser { return [_thread.users firstObject]; }

- (void)viewDidLoad
{
    [super viewDidLoad];
    SHTheme *theme = [SHTheme shared];
    self.view.backgroundColor = [theme linenColor];

    // The title is a button: tapping the name opens the person's profile.
    UIButton *titleButton = [UIButton buttonWithType:UIButtonTypeCustom];
    titleButton.frame = CGRectMake(0, 0, 200, 32);
    [titleButton setTitle:[SHUtils displayText:_thread.title] forState:UIControlStateNormal];
    titleButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [titleButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [titleButton setTitleShadowColor:[UIColor colorWithWhite:0 alpha:0.6] forState:UIControlStateNormal];
    titleButton.titleLabel.shadowOffset = CGSizeMake(0, -1);
    titleButton.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [titleButton addTarget:self action:@selector(titleTapped) forControlEvents:UIControlEventTouchUpInside];
    self.navigationItem.titleView = titleButton;

    _tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, self.view.bounds.size.height - SHBarH) style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.allowsSelection = NO;
    [theme applyToTableView:_tableView];
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.view addSubview:_tableView];

    // the glossy iOS 6 input bar
    _inputBar = [[UIView alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height - SHBarH, self.view.bounds.size.width, SHBarH)];
    _inputBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    UIImageView *barArt = [[UIImageView alloc] initWithImage:[theme barBackgroundImage]];
    barArt.frame = _inputBar.bounds;
    barArt.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_inputBar addSubview:barArt];

    // the camera on the left, as in iOS 6 Messages: take a photo or choose one
    _cameraButton = [self barGlyphButton:[SHTabIcons cameraWithSize:20 color:[theme textColor] dark:theme.isDark] action:@selector(cameraTapped:)];
    _cameraButton.frame = CGRectMake(6, 8, 40, 32);
    _cameraButton.accessibilityLabel = L(@"Photo");
    [_inputBar addSubview:_cameraButton];

    _inputField = [[UITextField alloc] initWithFrame:CGRectMake(52, 8, _inputBar.bounds.size.width - 52 - 6 - 40 - 8 - 64 - 8, 32)];
    _inputField.borderStyle = UITextBorderStyleNone;
    _inputField.background = [theme textFieldBackgroundImage];
    _inputField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 32)];
    _inputField.leftViewMode = UITextFieldViewModeAlways;
    _inputField.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    _inputField.placeholder = L(@"Message...");
    _inputField.font = [UIFont systemFontOfSize:15];
    _inputField.textColor = [theme inputTextColor];
    _inputField.keyboardAppearance = theme.isDark ? UIKeyboardAppearanceAlert : UIKeyboardAppearanceDefault;
    _inputField.delegate = self;
    _inputField.returnKeyType = UIReturnKeySend;
    _inputField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_inputBar addSubview:_inputField];

    _sendButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _sendButton.frame = CGRectMake(_inputBar.bounds.size.width - 72, 8, 64, 32);
    _sendButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [_sendButton setTitle:L(@"Send") forState:UIControlStateNormal];
    [_sendButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _sendButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_sendButton setBackgroundImage:[theme accentButtonImageHighlighted:NO disabled:NO] forState:UIControlStateNormal];
    [_sendButton setBackgroundImage:[theme accentButtonImageHighlighted:YES disabled:NO] forState:UIControlStateHighlighted];
    [theme embossButton:_sendButton];
    [_sendButton addTarget:self action:@selector(sendTapped) forControlEvents:UIControlEventTouchUpInside];
    [_inputBar addSubview:_sendButton];

    // the microphone: a tap starts a voice message, Send sends it
    _micButton = [self barGlyphButton:[SHTabIcons microphoneWithSize:20 color:[theme textColor] dark:theme.isDark] action:@selector(micTapped)];
    _micButton.frame = CGRectMake(_inputBar.bounds.size.width - 72 - 8 - 40, 8, 40, 32);
    _micButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    _micButton.accessibilityLabel = L(@"Voice message");
    [_inputBar addSubview:_micButton];

    // while recording: Cancel, a red light and the time, over the camera, the field and the microphone
    _recordView = [[UIView alloc] initWithFrame:CGRectMake(6, 6, _inputBar.bounds.size.width - 72 - 12, 36)];
    _recordView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _recordView.backgroundColor = [UIColor clearColor];
    _recordView.hidden = YES;
    UIButton *cancelRecording = [self barGlyphButton:nil action:@selector(cancelRecording)];
    [cancelRecording setTitle:L(@"Cancel") forState:UIControlStateNormal];
    [cancelRecording setTitleColor:[theme textColor] forState:UIControlStateNormal];
    cancelRecording.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [theme embossButton:cancelRecording];
    CGFloat cancelW = MAX(70, [L(@"Cancel") sizeWithFont:cancelRecording.titleLabel.font].width + 24);
    cancelRecording.frame = CGRectMake(0, 2, cancelW, 32);
    [_recordView addSubview:cancelRecording];
    _recordDot = [[UIImageView alloc] initWithImage:[self recordDotImage]];
    _recordDot.frame = CGRectMake(cancelW + 14, 11, 14, 14);
    [_recordView addSubview:_recordDot];
    _recordLabel = [[UILabel alloc] initWithFrame:CGRectMake(cancelW + 36, 0, _recordView.bounds.size.width - cancelW - 40, 36)];
    _recordLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _recordLabel.font = [UIFont boldSystemFontOfSize:15];
    _recordLabel.textColor = [theme textColor];
    _recordLabel.backgroundColor = [UIColor clearColor];
    [theme embossLabel:_recordLabel];
    [_recordView addSubview:_recordLabel];
    [_inputBar addSubview:_recordView];
    [self.view addSubview:_inputBar];

    // a picked photo waits above the bar until Send (or Remove)
    _attachmentView = [[UIView alloc] initWithFrame:CGRectMake(0, _inputBar.frame.origin.y - SHAttachH, self.view.bounds.size.width, SHAttachH)];
    _attachmentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    _attachmentView.hidden = YES;
    UIImageView *attachArt = [[UIImageView alloc] initWithImage:[theme barBackgroundImage]];
    attachArt.frame = _attachmentView.bounds;
    attachArt.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_attachmentView addSubview:attachArt];
    UIView *thumbFrame = [[UIView alloc] initWithFrame:CGRectMake(10, 6, 60, 60)];
    thumbFrame.backgroundColor = [UIColor whiteColor];
    thumbFrame.layer.cornerRadius = 4;
    thumbFrame.layer.shadowColor = [UIColor blackColor].CGColor;
    thumbFrame.layer.shadowOpacity = 0.5;
    thumbFrame.layer.shadowRadius = 1.5;
    thumbFrame.layer.shadowOffset = CGSizeMake(0, 1);
    _attachmentThumb = [[UIImageView alloc] initWithFrame:CGRectInset(thumbFrame.bounds, 2, 2)];
    _attachmentThumb.contentMode = UIViewContentModeScaleAspectFill;
    _attachmentThumb.clipsToBounds = YES;
    [thumbFrame addSubview:_attachmentThumb];
    [_attachmentView addSubview:thumbFrame];
    UILabel *attachLabel = [[UILabel alloc] initWithFrame:CGRectMake(82, 0, self.view.bounds.size.width - 82 - 110, SHAttachH)];
    attachLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    attachLabel.text = L(@"Photo ready to send");
    attachLabel.font = [UIFont boldSystemFontOfSize:14];
    attachLabel.textColor = [theme textColor];
    attachLabel.backgroundColor = [UIColor clearColor];
    [theme embossLabel:attachLabel];
    [_attachmentView addSubview:attachLabel];
    UIButton *removeAttachment = [self barGlyphButton:nil action:@selector(removeAttachment)];
    [removeAttachment setTitle:L(@"Remove") forState:UIControlStateNormal];
    [removeAttachment setTitleColor:[theme textColor] forState:UIControlStateNormal];
    removeAttachment.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [theme embossButton:removeAttachment];
    removeAttachment.frame = CGRectMake(self.view.bounds.size.width - 96, floorf((SHAttachH - 32) / 2), 86, 32);
    removeAttachment.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [_attachmentView addSubview:removeAttachment];
    [self.view addSubview:_attachmentView];

    // The inbox preview only carried the last message; show it at once, then load the thread.
    [self setMessagesNewestFirst:_thread.messages];
    [self refresh];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillHideNotification object:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_task cancel];
    _playingPk = nil;   // no row reloads from a dying controller
    [self stopVoice];
    [self closeTransientUI];
    [_recorder cancel];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self stopVoice];
    if (!self.presentedViewController) {   // (not when the camera is what covers the chat)
        [self closeTransientUI];
        if (_recorder) [self cancelRecording];   // a recording ends with the chat
    }
}

// The photo menu and the library's popover go with the chat. A popover released while it is still on screen stops
// the app (UIKit raises in its dealloc), and both hold this controller as an unretained delegate.
- (void)closeTransientUI
{
    if (_photoSheet) {
        _photoSheet.delegate = nil;
        [_photoSheet dismissWithClickedButtonIndex:_photoSheet.cancelButtonIndex animated:NO];
        _photoSheet = nil;
    }
    if (_pickerPopover) {
        UIImagePickerController *picker = (UIImagePickerController *)_pickerPopover.contentViewController;
        if ([picker isKindOfClass:[UIImagePickerController class]]) picker.delegate = nil;
        [_pickerPopover dismissPopoverAnimated:NO];
        _pickerPopover = nil;
    }
}

- (void)setMessagesNewestFirst:(NSArray *)newestFirst
{
    [_messages removeAllObjects];
    for (SHDirectMessage *m in [[newestFirst reverseObjectEnumerator] allObjects]) [_messages addObject:m];
    [_tableView reloadData];
    [self scrollToBottom:NO];
}

- (void)refresh
{
    if (!_thread.threadId.length) return;
    [_task cancel];
    _task = [SHInstagram directThread:_thread.threadId cursor:nil completion:^(SHDirectThread *thread, NSString *cursor, NSError *error) {
        if (error) { if (self->_messages.count == 0) [SHUtils alertWithTitle:L(@"Direct") message:error.localizedDescription]; return; }
        if (!thread) return;
        [self indexUsers:thread.users];
        self->_olderCursor = cursor;
        [self setMessagesNewestFirst:thread.messages];
    }];
}

- (void)loadOlder
{
    if (_loadingOlder || !_olderCursor.length) return;
    _loadingOlder = YES;
    [SHInstagram directThread:_thread.threadId cursor:_olderCursor completion:^(SHDirectThread *thread, NSString *cursor, NSError *error) {
        self->_loadingOlder = NO;
        if (error || !thread.messages.count) { self->_olderCursor = nil; return; }
        [self indexUsers:thread.users];
        self->_olderCursor = cursor;
        NSArray *older = [[thread.messages reverseObjectEnumerator] allObjects];
        // keep the view where it was: remember the content height, insert on top, restore the offset
        CGFloat before = self->_tableView.contentSize.height;
        [self->_messages insertObjects:older atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, older.count)]];
        [self->_tableView reloadData];
        CGFloat after = self->_tableView.contentSize.height;
        self->_tableView.contentOffset = CGPointMake(0, self->_tableView.contentOffset.y + (after - before));
    }];
}

- (void)scrollToBottom:(BOOL)animated
{
    if (_messages.count == 0) return;
    NSIndexPath *ip = [NSIndexPath indexPathForRow:(NSInteger)_messages.count - 1 inSection:0];
    [_tableView scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionBottom animated:animated];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    if (scrollView == _tableView && scrollView.contentOffset.y < -50 && scrollView.isDragging) [self loadOlder];
}

#pragma mark - Keyboard

// The bar over the keyboard, the picked photo's strip over the bar, the messages above both.
- (void)layoutBars
{
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    CGFloat attachH = _attachmentView.hidden ? 0 : SHAttachH;
    _inputBar.frame = CGRectMake(0, h - SHBarH - _keyboardOverlap, w, SHBarH);
    _attachmentView.frame = CGRectMake(0, _inputBar.frame.origin.y - SHAttachH, w, SHAttachH);
    _tableView.frame = CGRectMake(0, 0, w, h - SHBarH - _keyboardOverlap - attachH);
}

- (void)keyboardWillChange:(NSNotification *)note
{
    CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect endInView = [self.view convertRect:end fromView:nil];
    _keyboardOverlap = MAX(0, self.view.bounds.size.height - endInView.origin.y);
    CGFloat dur = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:dur animations:^{ [self layoutBars]; } completion:^(BOOL f) { [self scrollToBottom:NO]; }];
}

#pragma mark - Actions

- (void)titleTapped
{
    SHUser *u = [self otherUser];
    if (!u.username.length && !u.pk.length) return;
    SHProfileViewController *vc = [[SHProfileViewController alloc] initWithUsername:u.username pk:u.pk];
    [self.navigationController pushViewController:vc animated:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField { [self sendTapped]; return NO; }

- (void)sendTapped
{
    if (_recorder) { [self sendVoice]; return; }   // Send ends the recording and sends it
    if (_pendingJPEG) [self sendPhoto];           // the photo first, then the text with it (if any)
    NSString *text = [_inputField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length || !_thread.threadId.length) return;

    SHDirectMessage *local = [[SHDirectMessage alloc] init];   // optimistic echo
    local.type = @"text";
    local.text = text;
    local.senderPk = _myId;
    local.timestamp = [NSDate date];
    [_messages addObject:local];
    [_tableView reloadData];
    [self scrollToBottom:YES];
    _inputField.text = @"";

    [SHInstagram sendDirectText:text toThread:_thread.threadId completion:^(BOOL ok, NSError *error) {
        if (!ok) [SHUtils alertWithTitle:L(@"Direct") message:error.localizedDescription ?: L(@"The message didn't send.")];
    }];
}

#pragma mark - The bar's buttons

- (UIButton *)barGlyphButton:(UIImage *)glyph action:(SEL)action
{
    SHTheme *theme = [SHTheme shared];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setBackgroundImage:[theme buttonImageHighlighted:NO] forState:UIControlStateNormal];
    [b setBackgroundImage:[theme buttonImageHighlighted:YES] forState:UIControlStateHighlighted];
    if (glyph) [b setImage:glyph forState:UIControlStateNormal];
    b.adjustsImageWhenHighlighted = NO;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

// The glossy red light of a recording.
- (UIImage *)recordDotImage
{
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(14, 14), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor colorWithRed:0.62f green:0.04f blue:0.04f alpha:1] setFill];
    CGContextFillEllipseInRect(ctx, CGRectMake(0.5f, 0.5f, 13, 13));
    [[UIColor colorWithRed:0.93f green:0.15f blue:0.12f alpha:1] setFill];
    CGContextFillEllipseInRect(ctx, CGRectMake(1.5f, 1.5f, 11, 11));
    [[UIColor colorWithWhite:1 alpha:0.5f] setFill];
    CGContextFillEllipseInRect(ctx, CGRectMake(4, 2.5f, 6, 4));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (void)appendLocal:(SHDirectMessage *)m
{
    m.pk = [@"local-" stringByAppendingString:[[NSUUID UUID] UUIDString]];
    [_messages addObject:m];
    [_tableView reloadData];
    [self scrollToBottom:YES];
}

// A photo or voice message sent from here: kept (no longer faded) once Instagram took it, then the thread is loaded
// again for the real thing; taken away again with a word if it did not go.
- (void)localMessage:(SHDirectMessage *)m sent:(BOOL)ok error:(NSError *)error
{
    m.sending = NO;
    if (!ok) {
        [_messages removeObjectIdenticalTo:m];
        [_tableView reloadData];
        [SHUtils alertWithTitle:L(@"Direct") message:error.localizedDescription ?: L(@"The message didn't send.")];
        return;
    }
    [_tableView reloadData];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self refresh]; });
}

#pragma mark - Photos

- (void)cameraTapped:(UIButton *)button
{
    [_inputField resignFirstResponder];
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    if ([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) [sheet addButtonWithTitle:L(@"Take Photo")];
    if ([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) [sheet addButtonWithTitle:L(@"Choose Existing")];
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:L(@"Cancel")];
    _photoSheet = sheet;
    if (SHIsPad()) [sheet showFromRect:button.bounds inView:button animated:YES];
    else [sheet showInView:self.view];
}

- (void)actionSheet:(UIActionSheet *)sheet didDismissWithButtonIndex:(NSInteger)index
{
    if (sheet == _photoSheet) _photoSheet = nil;
    if (index < 0 || index == sheet.cancelButtonIndex) return;
    NSString *title = [sheet buttonTitleAtIndex:index];
    if ([title isEqualToString:L(@"Take Photo")]) [self presentPickerWithSource:UIImagePickerControllerSourceTypeCamera];
    else if ([title isEqualToString:L(@"Choose Existing")]) [self presentPickerWithSource:UIImagePickerControllerSourceTypePhotoLibrary];
}

- (void)presentPickerWithSource:(UIImagePickerControllerSourceType)source
{
    if (![UIImagePickerController isSourceTypeAvailable:source]) return;
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = source;
    picker.delegate = self;
    if (SHIsPad() && source == UIImagePickerControllerSourceTypePhotoLibrary) {
        // the iPad shows the photo library only in a popover
        _pickerPopover = [[UIPopoverController alloc] initWithContentViewController:picker];
        [_pickerPopover presentPopoverFromRect:_cameraButton.bounds inView:_cameraButton permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
        return;
    }
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)closePicker:(UIImagePickerController *)picker
{
    if (_pickerPopover) { [_pickerPopover dismissPopoverAnimated:YES]; _pickerPopover = nil; return; }
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info
{
    UIImage *image = info[UIImagePickerControllerOriginalImage];
    [self closePicker:picker];
    if (image) [self attachPhoto:image];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker { [self closePicker:picker]; }

// The photo is made ready (upright, at most 1080) away from the main thread, then waits above the bar for Send.
- (void)attachPhoto:(UIImage *)image
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        UIImage *flat = nil;
        NSData *jpeg = SHJPEGForSending(image, &flat);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!jpeg.length) return;
            self->_pendingJPEG = jpeg;
            self->_pendingImage = flat;
            self->_attachmentThumb.image = flat;
            self->_attachmentView.hidden = NO;
            [UIView animateWithDuration:0.2 animations:^{ [self layoutBars]; } completion:^(BOOL f) { [self scrollToBottom:YES]; }];
        });
    });
}

- (void)removeAttachment
{
    _pendingJPEG = nil;
    _pendingImage = nil;
    _attachmentThumb.image = nil;
    _attachmentView.hidden = YES;
    [self layoutBars];
}

- (void)sendPhoto
{
    NSData *jpeg = _pendingJPEG;
    UIImage *image = _pendingImage;
    [self removeAttachment];
    if (!jpeg.length || !_thread.threadId.length) return;
    SHDirectMessage *local = [[SHDirectMessage alloc] init];
    local.type = @"media";
    local.senderPk = _myId;
    local.timestamp = [NSDate date];
    local.localImage = image;
    local.placeholderText = L(@"Photo");
    local.sending = YES;
    [self appendLocal:local];
    SHLog(@"Photo: sending %lu bytes", (unsigned long)jpeg.length);
    [SHInstagram sendDirectPhoto:jpeg toThread:_thread.threadId completion:^(BOOL ok, NSError *error) {
        [self localMessage:local sent:ok error:error];
    }];
}

// Debug builds: a plain test picture in place of the camera (the URL command dmtestphoto), to try the sending.
- (void)debugAttachTestPhoto
{
    CGSize size = CGSizeMake(800, 600);
    UIGraphicsBeginImageContextWithOptions(size, YES, 1);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[8] = { 0.16f, 0.42f, 0.85f, 1, 0.05f, 0.18f, 0.45f, 1 };
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, comps, NULL, 2);
    CGContextDrawLinearGradient(ctx, gradient, CGPointZero, CGPointMake(0, size.height), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
    [[UIColor whiteColor] setFill];
    NSString *s = @"Gramify test";
    UIFont *font = [UIFont boldSystemFontOfSize:64];
    CGSize ts = [s sizeWithFont:font];
    [s drawAtPoint:CGPointMake(floorf((size.width - ts.width) / 2), floorf((size.height - ts.height) / 2)) withFont:font];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    [self attachPhoto:img];
}

#pragma mark - Recording

- (void)micTapped
{
    if (_recorder) return;
    [_inputField resignFirstResponder];
    [self stopVoice];
    AVAudioSession *session = [AVAudioSession sharedInstance];
    SEL ask = NSSelectorFromString(@"requestRecordPermission:");
    if ([session respondsToSelector:ask]) {
        // iOS 7 and newer ask the user once before the microphone hears anything
        __weak SHThreadViewController *weakSelf = self;
        void (^answer)(BOOL) = ^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (granted) [weakSelf startRecording];
                else [SHUtils alertWithTitle:L(@"Voice message") message:L(@"Gramify can't use the microphone. Allow it in Settings > Privacy > Microphone.")];
            });
        };
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [session performSelector:ask withObject:answer];
#pragma clang diagnostic pop
        return;
    }
    [self startRecording];
}

- (void)startRecording
{
    if (_recorder) return;
    SHVoiceRecorder *rec = [[SHVoiceRecorder alloc] init];
    __weak SHThreadViewController *weakSelf = self;
    rec.onTick = ^(NSTimeInterval seconds) { [weakSelf showRecordingTime:seconds full:NO]; };
    rec.onLimit = ^{ [weakSelf showRecordingTime:SHVoiceLimit full:YES]; };
    if (![rec start]) {
        [SHUtils alertWithTitle:L(@"Voice message") message:L(@"The microphone could not be started.")];
        return;
    }
    _recorder = rec;
    [self showRecordingTime:0 full:NO];
    _recordView.hidden = NO;
    _cameraButton.hidden = _inputField.hidden = _micButton.hidden = YES;
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @1;
    pulse.toValue = @0.25;
    pulse.duration = 0.6;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    [_recordDot.layer addAnimation:pulse forKey:@"pulse"];
    SHLog(@"Voice: recording");
}

- (void)showRecordingTime:(NSTimeInterval)seconds full:(BOOL)full
{
    _recordLabel.text = [NSString stringWithFormat:@"%@  %@", full ? L(@"Ready to send") : L(@"Recording"), [SHUtils formatDuration:seconds]];
    if (full) [_recordDot.layer removeAnimationForKey:@"pulse"];
}

- (void)endRecordingUI
{
    [_recordDot.layer removeAnimationForKey:@"pulse"];
    _recordView.hidden = YES;
    _cameraButton.hidden = _inputField.hidden = _micButton.hidden = NO;
}

- (void)cancelRecording
{
    [_recorder cancel];
    _recorder = nil;
    [self endRecordingUI];
}

- (void)sendVoice
{
    SHVoiceRecorder *rec = _recorder;
    _recorder = nil;
    NSData *audio = [rec finish];
    [self endRecordingUI];
    if (!audio.length) { [SHShareViewController flashMessage:L(@"Too short")]; return; }
    if (!_thread.threadId.length) return;
    SHDirectMessage *local = [[SHDirectMessage alloc] init];
    local.type = @"voice_media";
    local.senderPk = _myId;
    local.timestamp = [NSDate date];
    local.audioURL = [[NSURL fileURLWithPath:rec.path] absoluteString];
    local.audioDuration = rec.duration;
    local.placeholderText = L(@"Voice message");
    local.sending = YES;
    [self appendLocal:local];
    SHLog(@"Voice: sending %.1f s, %lu bytes, %lu levels", rec.duration, (unsigned long)audio.length, (unsigned long)rec.waveform.count);
    [SHInstagram sendDirectVoice:audio duration:rec.duration waveform:rec.waveform toThread:_thread.threadId completion:^(BOOL ok, NSError *error) {
        [self localMessage:local sent:ok error:error];
    }];
}

#pragma mark - Voice messages

static void *SHVoiceStatusContext = &SHVoiceStatusContext;

- (void)stopVoice
{
    [_voicePlayer pause];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
    if (_voicePlayer) {
        if (_voiceTimeObserver) [_voicePlayer removeTimeObserver:_voiceTimeObserver];
        [_voicePlayer.currentItem removeObserver:self forKeyPath:@"status" context:SHVoiceStatusContext];
    }
    _voiceTimeObserver = nil;
    _voicePlayer = nil;
    _voiceProgress = 0;
    NSString *was = _playingPk;
    _playingPk = nil;
    if (was) [self reloadRowForPk:was];
}

- (void)playVoice:(SHDirectMessage *)m
{
    if ([_playingPk isEqualToString:m.pk]) { [self stopVoice]; return; }
    [self stopVoice];
    // The audio comes over the app's own media proxy (iOS 6 cannot speak the CDN's TLS itself); one just recorded
    // here plays from its file.
    NSString *proxied = [m.audioURL hasPrefix:@"file:"] ? m.audioURL : [[SHMediaProxy shared] proxyURLForURL:[NSURL URLWithString:m.audioURL]];
    if (!proxied.length) return;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL URLWithString:proxied]];
    _voicePlayer = [AVPlayer playerWithPlayerItem:item];
    [item addObserver:self forKeyPath:@"status" options:0 context:SHVoiceStatusContext];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(voiceFinished:) name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    // the groove fills four times a second
    __weak SHThreadViewController *weakSelf = self;
    NSTimeInterval knownDuration = m.audioDuration;
    _voiceTimeObserver = [_voicePlayer addPeriodicTimeObserverForInterval:CMTimeMake(1, 4) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
        [weakSelf voiceTick:CMTimeGetSeconds(time) knownDuration:knownDuration];
    }];
    _playingPk = m.pk;
    [_voicePlayer play];
    [self reloadRowForPk:m.pk];
    SHLog(@"Voice: playing %@", m.pk);
}

- (void)voiceTick:(NSTimeInterval)seconds knownDuration:(NSTimeInterval)knownDuration
{
    NSTimeInterval duration = CMTimeGetSeconds(_voicePlayer.currentItem.duration);
    if (!(duration > 0) || isnan(duration)) duration = knownDuration;
    if (!(duration > 0) || isnan(seconds)) return;
    _voiceProgress = (CGFloat)MIN(1.0, seconds / duration);
    for (UITableViewCell *c in _tableView.visibleCells) {
        SHBubbleCell *cell = (SHBubbleCell *)c;
        if ([c isKindOfClass:[SHBubbleCell class]] && [cell.message.pk isEqualToString:_playingPk]) [cell setVoiceProgress:_voiceProgress];
    }
}

- (void)voiceFinished:(NSNotification *)note { [self stopVoice]; }

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context != SHVoiceStatusContext) { [super observeValueForKeyPath:keyPath ofObject:object change:change context:context]; return; }
    AVPlayerItem *item = object;
    if (item.status == AVPlayerItemStatusFailed) {
        SHLog(@"Voice: playback failed: %@", item.error.localizedDescription);
        [self stopVoice];
        [SHUtils alertWithTitle:L(@"Voice message") message:L(@"Couldn't play the voice message.")];
    } else if (item.status == AVPlayerItemStatusReadyToPlay) {
        SHLog(@"Voice: ready, %.1f s", CMTimeGetSeconds(item.duration));
    }
}

- (void)reloadRowForPk:(NSString *)pk
{
    for (NSUInteger i = 0; i < _messages.count; i++) {
        if ([[_messages[i] pk] isEqualToString:pk]) {
            [_tableView reloadRowsAtIndexPaths:@[ [NSIndexPath indexPathForRow:(NSInteger)i inSection:0] ] withRowAnimation:UITableViewRowAnimationNone];
            return;
        }
    }
}

#pragma mark - SHBubbleCellDelegate

- (void)bubbleCell:(SHBubbleCell *)cell didTapAvatarOfUser:(SHUser *)user
{
    if (!user.username.length && !user.pk.length) return;
    SHProfileViewController *vc = [[SHProfileViewController alloc] initWithUsername:user.username pk:user.pk];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)bubbleCell:(SHBubbleCell *)cell didTapMessage:(SHDirectMessage *)m
{
    if (m.audioURL.length) { [self playVoice:m]; return; }
    if (m.sharedPost) {
        [self.navigationController pushViewController:[[SHPostDetailViewController alloc] initWithPost:m.sharedPost] animated:YES];
        return;
    }
    // a share in the newer form carries just its link: the post, reel or profile opens from that
    if (m.targetURL.length && [SHLinkRouter openLink:m.targetURL]) return;
    if (m.previewURL.length) {
        // a photo or video sent directly: show it full size through the post screen
        SHPost *p = [[SHPost alloc] init];
        p.pk = m.pk ?: @"";
        p.mediaType = m.videoURL.length ? 2 : 1;
        p.videoURL = m.videoURL;
        SHMediaImage *img = [[SHMediaImage alloc] init];
        img.url = m.previewURL;
        img.width = 1;
        img.height = 1;
        p.image = p.mediumImage = p.thumbImage = img;
        p.user = _usersByPk[m.senderPk ?: @""];
        [self.navigationController pushViewController:[[SHPostDetailViewController alloc] initWithPost:p] animated:YES];
        return;
    }
    if ([m.type isEqualToString:@"link"] && m.text.length) {
        NSArray *links = [SHUtils webLinksInText:m.text];
        NSMutableArray *urls = [NSMutableArray array];
        for (NSTextCheckingResult *r in links) if (r.URL) [urls addObject:r.URL];
        if (urls.count) [SHLinkRouter openWebLinks:urls from:self anchor:cell];
    }
}

#pragma mark - Table

- (NSString *)timeTextFor:(SHDirectMessage *)m
{
    if (!m.timestamp) return @"";
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSUInteger units = NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit;   // (iOS 6 names)
    NSDateComponents *a = [cal components:units fromDate:m.timestamp];
    NSDateComponents *b = [cal components:units fromDate:[NSDate date]];
    BOOL today = a.year == b.year && a.month == b.month && a.day == b.day;
    return [today ? _timeFormatter : _dateFormatter stringFromDate:m.timestamp];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_messages.count; }

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return [SHBubbleCell heightForMessage:_messages[(NSUInteger)indexPath.row] width:tableView.bounds.size.width];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    SHBubbleCell *cell = [tableView dequeueReusableCellWithIdentifier:SHMsgCellId];
    if (!cell) cell = [[SHBubbleCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:SHMsgCellId];
    cell.delegate = self;
    NSUInteger i = (NSUInteger)indexPath.row;
    SHDirectMessage *m = _messages[i];
    BOOL outgoing = m.senderPk.length && [m.senderPk isEqualToString:_myId];
    // the picture sits by the last bubble of a run from the same sender, as in the real app
    BOOL lastOfRun = i + 1 >= _messages.count || ![[_messages[i + 1] senderPk] isEqualToString:m.senderPk];
    BOOL playing = [_playingPk isEqualToString:m.pk];
    [cell configureWithMessage:m outgoing:outgoing sender:_usersByPk[m.senderPk ?: @""] showAvatar:lastOfRun
                         width:tableView.bounds.size.width playing:playing progress:playing ? _voiceProgress : 0 timeText:[self timeTextFor:m]];
    return cell;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
