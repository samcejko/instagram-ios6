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
#import "SHCommon.h"
#import <AVFoundation/AVFoundation.h>
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
@property (nonatomic, strong) UILabel *textLabel2;
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

// The size of the bubble for a message, given the table width.
+ (CGSize)bubbleSizeForMessage:(SHDirectMessage *)m width:(CGFloat)width
{
    CGFloat tail = [[SHTheme shared] bubbleTailWidth];
    if (SHIsLike(m)) return CGSizeMake(SHLikeSide, SHLikeSide);
    if (m.audioURL.length) return CGSizeMake(SHVoiceW, SHVoiceH);
    if (m.previewURL.length) return CGSizeMake(SHMediaSide, SHMediaSide + (m.sharedPost ? 20 : 0));
    NSString *text = m.text.length ? m.text : (m.placeholderText ?: @" ");
    CGFloat maxw = floorf(width * SHBubbleMaxFrac) - SHBubblePadX * 2 - tail;
    CGSize sz = [[SHUtils displayText:text] sizeWithFont:[UIFont systemFontOfSize:SHBubbleFont]
                                        constrainedToSize:CGSizeMake(maxw, 4000) lineBreakMode:NSLineBreakByWordWrapping];
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
        [_bubble addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bubbleTapped)]];
        [self.contentView addSubview:_bubble];

        _textLabel2 = [[UILabel alloc] initWithFrame:CGRectZero];
        _textLabel2.numberOfLines = 0;
        _textLabel2.font = [UIFont systemFontOfSize:SHBubbleFont];
        _textLabel2.backgroundColor = [UIColor clearColor];
        _textLabel2.lineBreakMode = NSLineBreakByWordWrapping;
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
    BOOL isMedia = !isLike && !isVoice && m.previewURL.length > 0;
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
    _playBadge.hidden = !(isMedia && (m.videoURL.length || m.sharedPost.videoURL.length || m.sharedPost.mediaType == 2));
    _captionLabel.hidden = !(isMedia && m.sharedPost);
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
        [_media setImageURL:m.previewURL placeholder:nil];
        _playBadge.frame = CGRectMake(SHMediaSide / 2 - 22, SHMediaSide / 2 - 22, 44, 44);
        if (m.sharedPost) {
            _captionLabel.frame = CGRectMake(8, SHMediaSide, SHMediaSide - 16, 20);
            _captionLabel.textColor = [UIColor whiteColor];
            _captionLabel.text = m.sharedPost.user.username.length ? [@"@" stringByAppendingString:m.sharedPost.user.username] : L(@"Shared a post");
        }
    } else {
        [_media setImageURL:nil placeholder:nil];
        BOOL placeholder = m.text.length == 0;
        _textLabel2.text = [SHUtils displayText:m.text.length ? m.text : (m.placeholderText ?: @"")];
        _textLabel2.textColor = placeholder ? [fg colorWithAlphaComponent:0.75] : fg;
        _textLabel2.shadowColor = shadow;
        _textLabel2.shadowOffset = shadowOffset;
        _textLabel2.font = placeholder ? [UIFont italicSystemFontOfSize:SHBubbleFont] : [UIFont systemFontOfSize:SHBubbleFont];
        _textLabel2.frame = CGRectMake(inset + SHBubblePadX, SHBubblePadY, bsz.width - SHBubblePadX * 2 - tail, bsz.height - SHBubblePadY * 2);
    }

    _timeLabel.text = timeText ?: @"";
    _timeLabel.textAlignment = outgoing ? NSTextAlignmentRight : NSTextAlignmentLeft;
    _timeLabel.frame = outgoing ? CGRectMake(x - 60, SHRowGap + bsz.height + 2, bsz.width + 60 - tail - 4, SHTimeH)
                                : CGRectMake(x + tail + 4, SHRowGap + bsz.height + 2, bsz.width + 60, SHTimeH);
}

@end

#pragma mark - Thread

@interface SHThreadViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, SHBubbleCellDelegate>
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

    _inputField = [[UITextField alloc] initWithFrame:CGRectMake(8, 8, _inputBar.bounds.size.width - 86, 32)];
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
    [self.view addSubview:_inputBar];

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
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self stopVoice];
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

- (void)keyboardWillChange:(NSNotification *)note
{
    CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect endInView = [self.view convertRect:end fromView:nil];
    CGFloat overlap = MAX(0, self.view.bounds.size.height - endInView.origin.y);
    CGFloat dur = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:dur animations:^{
        self->_inputBar.frame = CGRectMake(0, self.view.bounds.size.height - SHBarH - overlap, self.view.bounds.size.width, SHBarH);
        self->_tableView.frame = CGRectMake(0, 0, self.view.bounds.size.width, self.view.bounds.size.height - SHBarH - overlap);
    } completion:^(BOOL f) { [self scrollToBottom:NO]; }];
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
    // The audio comes over the app's own media proxy (iOS 6 cannot speak the CDN's TLS itself).
    NSString *proxied = [[SHMediaProxy shared] proxyURLForURL:[NSURL URLWithString:m.audioURL]];
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
