#import "SHThreadViewController.h"
#import "SHProfileViewController.h"
#import "SHPostDetailViewController.h"
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

static NSString * const SHMsgCellId = @"MsgCell";

// Bubble geometry
static const CGFloat SHBubbleMaxFrac = 0.70;   // of the table width
static const CGFloat SHBubbleFont    = 15.0;
static const CGFloat SHBubblePadX    = 12.0;
static const CGFloat SHBubblePadY    = 8.0;
static const CGFloat SHAvatarSize    = 28.0;
static const CGFloat SHMediaSide     = 200.0;
static const CGFloat SHVoiceW        = 210.0;
static const CGFloat SHVoiceH        = 44.0;
static const CGFloat SHTimeH         = 14.0;
static const CGFloat SHRowGap        = 5.0;
static const CGFloat SHEdge          = 10.0;
static const CGFloat SHBarH          = 48.0;

#pragma mark - Bubble cell

@class SHBubbleCell;
@protocol SHBubbleCellDelegate <NSObject>
- (void)bubbleCell:(SHBubbleCell *)cell didTapAvatarOfUser:(SHUser *)user;
- (void)bubbleCell:(SHBubbleCell *)cell didTapMessage:(SHDirectMessage *)message;
@end

@interface SHBubbleCell : UITableViewCell
@property (nonatomic, weak) id<SHBubbleCellDelegate> delegate;
@property (nonatomic, strong) SHDirectMessage *message;
@property (nonatomic, strong) SHUser *sender;
@property (nonatomic, strong) SHImageView *avatar;
@property (nonatomic, strong) UIView *bubble;
@property (nonatomic, strong) UILabel *textLabel2;
@property (nonatomic, strong) SHImageView *media;
@property (nonatomic, strong) UILabel *playBadge;
@property (nonatomic, strong) UILabel *captionLabel;   // "@user" under a shared post
@property (nonatomic, strong) UIButton *voiceButton;
@property (nonatomic, strong) UILabel *voiceLabel;
@property (nonatomic, strong) UIView *voiceTrack;
@property (nonatomic, strong) UILabel *timeLabel;
+ (CGFloat)heightForMessage:(SHDirectMessage *)m width:(CGFloat)width;
- (void)configureWithMessage:(SHDirectMessage *)m outgoing:(BOOL)outgoing sender:(SHUser *)sender showAvatar:(BOOL)showAvatar
                       width:(CGFloat)width playing:(BOOL)playing timeText:(NSString *)timeText;
@end

@implementation SHBubbleCell

// The size of the bubble's content for a message, given the table width.
+ (CGSize)bubbleSizeForMessage:(SHDirectMessage *)m width:(CGFloat)width
{
    if (m.audioURL.length) return CGSizeMake(SHVoiceW, SHVoiceH);
    if (m.previewURL.length) return CGSizeMake(SHMediaSide, SHMediaSide + (m.sharedPost ? 18 : 0));
    NSString *text = m.text.length ? m.text : (m.placeholderText ?: @" ");
    CGFloat maxw = floorf(width * SHBubbleMaxFrac) - SHBubblePadX * 2;
    CGSize sz = [[SHUtils displayText:text] sizeWithFont:[UIFont systemFontOfSize:SHBubbleFont]
                                        constrainedToSize:CGSizeMake(maxw, 4000) lineBreakMode:NSLineBreakByWordWrapping];
    return CGSizeMake(MAX(sz.width, 10) + SHBubblePadX * 2, MAX(sz.height, 18) + SHBubblePadY * 2);
}

+ (CGFloat)heightForMessage:(SHDirectMessage *)m width:(CGFloat)width
{
    return SHRowGap + [self bubbleSizeForMessage:m width:width].height + 2 + SHTimeH + SHRowGap;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [[SHTheme shared] backgroundColor];
        self.contentView.backgroundColor = [[SHTheme shared] backgroundColor];

        _avatar = [[SHImageView alloc] initWithFrame:CGRectMake(SHEdge, 0, SHAvatarSize, SHAvatarSize)];
        _avatar.layer.cornerRadius = SHAvatarSize / 2;
        _avatar.clipsToBounds = YES;
        _avatar.maxPixels = 96;
        _avatar.backgroundColor = [[SHTheme shared] separatorColor];
        _avatar.userInteractionEnabled = YES;
        [_avatar addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(avatarTapped)]];
        [self.contentView addSubview:_avatar];

        _bubble = [[UIView alloc] initWithFrame:CGRectZero];
        _bubble.layer.cornerRadius = 16;
        _bubble.clipsToBounds = YES;
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
        _media.backgroundColor = [[SHTheme shared] separatorColor];
        [_bubble addSubview:_media];

        _playBadge = [[UILabel alloc] initWithFrame:CGRectZero];
        _playBadge.text = @"▶";
        _playBadge.font = [UIFont boldSystemFontOfSize:22];
        _playBadge.textColor = [UIColor whiteColor];
        _playBadge.textAlignment = NSTextAlignmentCenter;
        _playBadge.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
        _playBadge.layer.cornerRadius = 22;
        _playBadge.clipsToBounds = YES;
        [_bubble addSubview:_playBadge];

        _captionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _captionLabel.font = [UIFont boldSystemFontOfSize:11];
        _captionLabel.backgroundColor = [UIColor clearColor];
        [_bubble addSubview:_captionLabel];

        _voiceButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _voiceButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
        [_voiceButton addTarget:self action:@selector(bubbleTapped) forControlEvents:UIControlEventTouchUpInside];
        [_bubble addSubview:_voiceButton];

        _voiceTrack = [[UIView alloc] initWithFrame:CGRectZero];
        _voiceTrack.layer.cornerRadius = 1.5;
        [_bubble addSubview:_voiceTrack];

        _voiceLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _voiceLabel.font = [UIFont systemFontOfSize:12];
        _voiceLabel.backgroundColor = [UIColor clearColor];
        [_bubble addSubview:_voiceLabel];

        _timeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _timeLabel.font = [UIFont systemFontOfSize:10];
        _timeLabel.textColor = [[SHTheme shared] secondaryTextColor];
        _timeLabel.backgroundColor = [UIColor clearColor];
        [self.contentView addSubview:_timeLabel];
    }
    return self;
}

- (void)avatarTapped { if (_sender) [self.delegate bubbleCell:self didTapAvatarOfUser:_sender]; }
- (void)bubbleTapped { if (_message) [self.delegate bubbleCell:self didTapMessage:_message]; }

- (void)configureWithMessage:(SHDirectMessage *)m outgoing:(BOOL)outgoing sender:(SHUser *)sender showAvatar:(BOOL)showAvatar
                       width:(CGFloat)width playing:(BOOL)playing timeText:(NSString *)timeText
{
    _message = m;
    _sender = sender;
    SHTheme *theme = [SHTheme shared];
    BOOL isVoice = m.audioURL.length > 0;
    BOOL isMedia = !isVoice && m.previewURL.length > 0;
    UIColor *fg = outgoing ? [UIColor whiteColor] : [theme textColor];

    CGSize bsz = [SHBubbleCell bubbleSizeForMessage:m width:width];
    CGFloat avatarRoom = (!outgoing && showAvatar) ? SHAvatarSize + 6 : 0;
    CGFloat x = outgoing ? width - SHEdge - bsz.width : SHEdge + avatarRoom;
    _bubble.frame = CGRectMake(x, SHRowGap, bsz.width, bsz.height);
    _bubble.backgroundColor = outgoing ? [SHUtils colorFromHex:@"#1A8CF0"] : [theme cardColor];

    _avatar.hidden = outgoing || !showAvatar;
    if (!_avatar.hidden) {
        _avatar.frame = CGRectMake(SHEdge, SHRowGap + bsz.height - SHAvatarSize, SHAvatarSize, SHAvatarSize);
        [_avatar setImageURL:sender.profilePicURL placeholder:[theme avatarPlaceholderWithSize:SHAvatarSize]];
    }

    _textLabel2.hidden = isVoice || isMedia;
    _media.hidden = !isMedia;
    _playBadge.hidden = !(isMedia && (m.videoURL.length || m.sharedPost.videoURL.length || m.sharedPost.mediaType == 2));
    _captionLabel.hidden = !(isMedia && m.sharedPost);
    _voiceButton.hidden = _voiceTrack.hidden = _voiceLabel.hidden = !isVoice;

    if (isVoice) {
        [_voiceButton setTitle:playing ? @"❚❚" : @"▶" forState:UIControlStateNormal];
        [_voiceButton setTitleColor:fg forState:UIControlStateNormal];
        _voiceButton.frame = CGRectMake(6, 0, 40, SHVoiceH);
        _voiceTrack.frame = CGRectMake(50, SHVoiceH / 2 - 1.5, SHVoiceW - 50 - 56, 3);
        _voiceTrack.backgroundColor = [fg colorWithAlphaComponent:0.5];
        _voiceLabel.frame = CGRectMake(SHVoiceW - 52, 0, 46, SHVoiceH);
        _voiceLabel.textColor = fg;
        _voiceLabel.textAlignment = NSTextAlignmentRight;
        _voiceLabel.text = m.audioDuration > 0 ? [SHUtils formatDuration:m.audioDuration] : L(@"Voice");
        [_media setImageURL:nil placeholder:nil];
    } else if (isMedia) {
        _media.frame = CGRectMake(0, 0, SHMediaSide, SHMediaSide);
        [_media setImageURL:m.previewURL placeholder:nil];
        _playBadge.frame = CGRectMake(SHMediaSide / 2 - 22, SHMediaSide / 2 - 22, 44, 44);
        if (m.sharedPost) {
            _captionLabel.frame = CGRectMake(8, SHMediaSide, SHMediaSide - 16, 18);
            _captionLabel.textColor = fg;
            _captionLabel.text = m.sharedPost.user.username.length ? [@"@" stringByAppendingString:m.sharedPost.user.username] : L(@"Shared a post");
        }
    } else {
        [_media setImageURL:nil placeholder:nil];
        BOOL placeholder = m.text.length == 0;
        _textLabel2.text = [SHUtils displayText:m.text.length ? m.text : (m.placeholderText ?: @"")];
        _textLabel2.textColor = placeholder ? [fg colorWithAlphaComponent:0.7] : fg;
        _textLabel2.font = placeholder ? [UIFont italicSystemFontOfSize:SHBubbleFont] : [UIFont systemFontOfSize:SHBubbleFont];
        _textLabel2.frame = CGRectMake(SHBubblePadX, SHBubblePadY, bsz.width - SHBubblePadX * 2, bsz.height - SHBubblePadY * 2);
    }

    _timeLabel.text = timeText ?: @"";
    _timeLabel.textAlignment = outgoing ? NSTextAlignmentRight : NSTextAlignmentLeft;
    _timeLabel.frame = CGRectMake(outgoing ? x - 60 : x + 4, SHRowGap + bsz.height + 2, bsz.width + 56, SHTimeH);
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
    self.view.backgroundColor = [[SHTheme shared] backgroundColor];

    // The title is a button: tapping the name opens the person's profile.
    UIButton *titleButton = [UIButton buttonWithType:UIButtonTypeCustom];
    titleButton.frame = CGRectMake(0, 0, 200, 32);
    [titleButton setTitle:_thread.title forState:UIControlStateNormal];
    titleButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [titleButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    titleButton.titleLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.6];
    titleButton.titleLabel.shadowOffset = CGSizeMake(0, -1);
    titleButton.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [titleButton addTarget:self action:@selector(titleTapped) forControlEvents:UIControlEventTouchUpInside];
    self.navigationItem.titleView = titleButton;

    _tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, self.view.bounds.size.height - SHBarH) style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.allowsSelection = NO;
    [[SHTheme shared] applyToTableView:_tableView];
    [self.view addSubview:_tableView];

    // the glossy iOS 6 input bar
    _inputBar = [[UIView alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height - SHBarH, self.view.bounds.size.width, SHBarH)];
    _inputBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    UIImageView *barArt = [[UIImageView alloc] initWithImage:[[SHTheme shared] barBackgroundImage]];
    barArt.frame = _inputBar.bounds;
    barArt.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_inputBar addSubview:barArt];

    _inputField = [[UITextField alloc] initWithFrame:CGRectMake(8, 8, _inputBar.bounds.size.width - 86, 32)];
    _inputField.borderStyle = UITextBorderStyleNone;
    _inputField.background = [[SHTheme shared] textFieldBackgroundImage];
    _inputField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 32)];
    _inputField.leftViewMode = UITextFieldViewModeAlways;
    _inputField.placeholder = L(@"Message...");
    _inputField.font = [UIFont systemFontOfSize:15];
    _inputField.textColor = [[SHTheme shared] inputTextColor];
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
    [_sendButton setBackgroundImage:[[SHTheme shared] accentButtonImageHighlighted:NO disabled:NO] forState:UIControlStateNormal];
    [_sendButton setBackgroundImage:[[SHTheme shared] accentButtonImageHighlighted:YES disabled:NO] forState:UIControlStateHighlighted];
    [[SHTheme shared] embossButton:_sendButton];
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
    [_voicePlayer pause];
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

- (void)stopVoice
{
    [_voicePlayer pause];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
    _voicePlayer = nil;
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
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL URLWithString:proxied]];
    _voicePlayer = [AVPlayer playerWithPlayerItem:item];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(voiceFinished:) name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    _playingPk = m.pk;
    [_voicePlayer play];
    [self reloadRowForPk:m.pk];
}

- (void)voiceFinished:(NSNotification *)note { [self stopVoice]; }

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
    [cell configureWithMessage:m outgoing:outgoing sender:_usersByPk[m.senderPk ?: @""] showAvatar:lastOfRun
                         width:tableView.bounds.size.width playing:[_playingPk isEqualToString:m.pk] timeText:[self timeTextFor:m]];
    return cell;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
