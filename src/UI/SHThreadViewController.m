#import "SHThreadViewController.h"
#import "SHInstagram.h"
#import "SHModels.h"
#import "SHSettings.h"
#import "SHImageLoader.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHCommon.h"

static NSString * const SHMsgCellId = @"MsgCell";
#define SH_BUBBLE_MAXW 0.72
#define SH_BUBBLE_FONT 15.0

@interface SHBubbleCell : UITableViewCell
@property (nonatomic, strong) UILabel *bubble;
@property (nonatomic, strong) SHImageView *media;
- (void)configureText:(NSString *)text mediaURL:(NSString *)mediaURL outgoing:(BOOL)outgoing width:(CGFloat)width;
+ (CGFloat)heightForText:(NSString *)text hasMedia:(BOOL)hasMedia width:(CGFloat)width;
@end

@implementation SHBubbleCell

+ (CGSize)textSize:(NSString *)text width:(CGFloat)width
{
    CGFloat maxw = width * SH_BUBBLE_MAXW - 24;
    CGSize sz = [text ?: @" " sizeWithFont:[UIFont systemFontOfSize:SH_BUBBLE_FONT]
                      constrainedToSize:CGSizeMake(maxw, 10000) lineBreakMode:NSLineBreakByWordWrapping];
    return sz;
}

+ (CGFloat)heightForText:(NSString *)text hasMedia:(BOOL)hasMedia width:(CGFloat)width
{
    if (hasMedia) return 160 + 10;
    CGSize sz = [self textSize:text width:width];
    return sz.height + 20 + 8;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = [[SHTheme shared] backgroundColor];
        self.contentView.backgroundColor = [[SHTheme shared] backgroundColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _bubble = [[UILabel alloc] initWithFrame:CGRectZero];
        _bubble.numberOfLines = 0;
        _bubble.font = [UIFont systemFontOfSize:SH_BUBBLE_FONT];
        _bubble.layer.cornerRadius = 16;
        _bubble.clipsToBounds = YES;
        _bubble.textAlignment = NSTextAlignmentLeft;
        [self.contentView addSubview:_bubble];
        _media = [[SHImageView alloc] initWithFrame:CGRectZero];
        _media.contentMode = UIViewContentModeScaleAspectFill;
        _media.clipsToBounds = YES;
        _media.layer.cornerRadius = 14;
        _media.backgroundColor = [[SHTheme shared] separatorColor];
        [self.contentView addSubview:_media];
    }
    return self;
}

- (void)configureText:(NSString *)text mediaURL:(NSString *)mediaURL outgoing:(BOOL)outgoing width:(CGFloat)width
{
    CGFloat pad = 10;
    if (mediaURL.length) {
        _bubble.hidden = YES;
        _media.hidden = NO;
        [_media setImageURL:mediaURL placeholder:nil];
        CGFloat mw = 120, mh = 160;
        _media.frame = CGRectMake(outgoing ? width - mw - pad : pad, 4, mw, mh);
    } else {
        _media.hidden = YES;
        [_media setImageURL:nil placeholder:nil];
        _bubble.hidden = NO;
        _bubble.text = [SHUtils displayText:text ?: @""];
        _bubble.backgroundColor = outgoing ? [SHUtils colorFromHex:@"#0095F6"] : [[SHTheme shared] cardColor];
        _bubble.textColor = outgoing ? [UIColor whiteColor] : [[SHTheme shared] textColor];
        CGSize sz = [SHBubbleCell textSize:text width:width];
        CGFloat bw = sz.width + 24, bh = sz.height + 16;
        _bubble.frame = CGRectMake(outgoing ? width - bw - pad : pad, 4, bw, bh);
        _bubble.textAlignment = NSTextAlignmentLeft;
        // inset the text inside the bubble
        _bubble.frame = CGRectMake(_bubble.frame.origin.x, 4, bw, bh);
    }
}
@end

@interface SHThreadViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) SHDirectThread *thread;
@property (nonatomic, strong) NSMutableArray *messages;   // chronological (oldest first)
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *inputBar;
@property (nonatomic, strong) UITextField *inputField;
@property (nonatomic, strong) UIButton *sendButton;
@property (nonatomic, strong) SHHTTPTask *task;
@property (nonatomic, copy) NSString *myId;
@property (nonatomic) CGFloat keyboardHeight;
@end

@implementation SHThreadViewController

- (instancetype)initWithThread:(SHDirectThread *)thread
{
    if ((self = [super init])) {
        _thread = thread;
        _messages = [NSMutableArray array];
        _myId = [SHSettings userId];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = _thread.title;
    self.view.backgroundColor = [[SHTheme shared] backgroundColor];

    CGFloat barH = 48;
    _tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, self.view.bounds.size.height - barH) style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.backgroundColor = [[SHTheme shared] backgroundColor];
    _tableView.allowsSelection = NO;
    [self.view addSubview:_tableView];

    _inputBar = [[UIView alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height - barH, self.view.bounds.size.width, barH)];
    _inputBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    _inputBar.backgroundColor = [[SHTheme shared] cardColor];
    UIView *hair = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _inputBar.bounds.size.width, 0.5)];
    hair.backgroundColor = [[SHTheme shared] separatorColor];
    hair.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_inputBar addSubview:hair];

    _inputField = [[UITextField alloc] initWithFrame:CGRectMake(10, 8, _inputBar.bounds.size.width - 80, 32)];
    _inputField.borderStyle = UITextBorderStyleRoundedRect;
    _inputField.placeholder = L(@"Message...");
    _inputField.font = [UIFont systemFontOfSize:15];
    _inputField.delegate = self;
    _inputField.returnKeyType = UIReturnKeySend;
    _inputField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_inputBar addSubview:_inputField];

    _sendButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _sendButton.frame = CGRectMake(_inputBar.bounds.size.width - 64, 8, 56, 32);
    _sendButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [_sendButton setTitle:L(@"Send") forState:UIControlStateNormal];
    [_sendButton setTitleColor:[SHUtils colorFromHex:@"#0095F6"] forState:UIControlStateNormal];
    _sendButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [_sendButton addTarget:self action:@selector(sendTapped) forControlEvents:UIControlEventTouchUpInside];
    [_inputBar addSubview:_sendButton];
    [self.view addSubview:_inputBar];

    // The thread arrives newest-first; show it oldest-first.
    for (SHDirectMessage *m in [[_thread.messages reverseObjectEnumerator] allObjects]) [_messages addObject:m];
    [_tableView reloadData];
    [self scrollToBottom:NO];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillHideNotification object:nil];

    [self refresh];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; [_task cancel]; }

- (void)refresh
{
    if (!_thread.threadId.length) return;
    [_task cancel];
    _task = [SHInstagram directThread:_thread.threadId cursor:nil completion:^(SHDirectThread *thread, NSString *cursor, NSError *error) {
        if (error || !thread) return;
        [self->_messages removeAllObjects];
        for (SHDirectMessage *m in [[thread.messages reverseObjectEnumerator] allObjects]) [self->_messages addObject:m];
        [self->_tableView reloadData];
        [self scrollToBottom:NO];
    }];
}

- (void)scrollToBottom:(BOOL)animated
{
    if (_messages.count == 0) return;
    NSIndexPath *ip = [NSIndexPath indexPathForRow:(NSInteger)_messages.count - 1 inSection:0];
    [_tableView scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionBottom animated:animated];
}

#pragma mark - Keyboard

- (void)keyboardWillChange:(NSNotification *)note
{
    CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect endInView = [self.view convertRect:end fromView:nil];
    CGFloat overlap = MAX(0, self.view.bounds.size.height - endInView.origin.y);
    _keyboardHeight = overlap;
    CGFloat barH = 48;
    CGFloat dur = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:dur animations:^{
        self->_inputBar.frame = CGRectMake(0, self.view.bounds.size.height - barH - overlap, self.view.bounds.size.width, barH);
        self->_tableView.frame = CGRectMake(0, 0, self.view.bounds.size.width, self.view.bounds.size.height - barH - overlap);
    } completion:^(BOOL f) { [self scrollToBottom:NO]; }];
}

#pragma mark - Send

- (BOOL)textFieldShouldReturn:(UITextField *)textField { [self sendTapped]; return NO; }

- (void)sendTapped
{
    NSString *text = [_inputField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length || !_thread.threadId.length) return;

    // Optimistic local echo.
    SHDirectMessage *local = [[SHDirectMessage alloc] init];
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

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_messages.count; }

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    SHDirectMessage *m = _messages[(NSUInteger)indexPath.row];
    NSString *text = m.text.length ? m.text : m.placeholderText;
    return [SHBubbleCell heightForText:text hasMedia:m.previewURL.length > 0 width:tableView.bounds.size.width];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    SHBubbleCell *cell = [tableView dequeueReusableCellWithIdentifier:SHMsgCellId];
    if (!cell) cell = [[SHBubbleCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:SHMsgCellId];
    SHDirectMessage *m = _messages[(NSUInteger)indexPath.row];
    BOOL outgoing = m.senderPk.length && [m.senderPk isEqualToString:_myId];
    NSString *text = m.text.length ? m.text : m.placeholderText;
    [cell configureText:text mediaURL:m.previewURL outgoing:outgoing width:tableView.bounds.size.width];
    return cell;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
