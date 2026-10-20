#import "SHCommentsViewController.h"
#import "SHInstagram.h"
#import "SHModels.h"
#import "SHImageLoader.h"
#import "SHLinkLabel.h"
#import "SHLinkRouter.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHCommon.h"

static const CGFloat SHCommentFont = 13;
static const CGFloat SHCommentAvatar = 32;
static const CGFloat SHCommentTextX = 52;

// "name comment": the name in bold (it opens the profile), the comment's @names, #tags and links live.
static NSAttributedString *SHCommentText(SHComment *c)
{
    UIColor *tc = [[SHTheme shared] textColor];
    NSString *name = c.user.username ?: @"";
    NSString *body = [SHUtils displayText:c.text] ?: @"";
    NSString *s = name.length ? [NSString stringWithFormat:@"%@ %@", name, body] : body;
    NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:s attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:SHCommentFont], NSForegroundColorAttributeName: tc }];
    if (name.length) [a addAttribute:NSFontAttributeName value:[UIFont boldSystemFontOfSize:SHCommentFont] range:NSMakeRange(0, name.length)];
    return a;
}

// A comment the way the app lists them: the picture, the text, the time under it.
@interface SHCommentCell : UITableViewCell
@property (nonatomic, strong) SHImageView *avatar;
@property (nonatomic, strong) SHLinkLabel *body;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) SHComment *comment;
- (void)configureWithComment:(SHComment *)comment;
@end

@implementation SHCommentCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        SHTheme *theme = [SHTheme shared];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _avatar = [[SHImageView alloc] initWithFrame:CGRectMake(10, 10, SHCommentAvatar, SHCommentAvatar)];
        [theme styleAvatar:_avatar radius:4];
        _avatar.maxPixels = 96;
        _avatar.userInteractionEnabled = YES;
        [_avatar addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(avatarTapped)]];
        [self.contentView addSubview:_avatar];
        _body = [[SHLinkLabel alloc] initWithFrame:CGRectZero];
        _body.shadowColor = theme.isDark ? [UIColor colorWithWhite:0 alpha:0.8] : [UIColor colorWithWhite:1 alpha:0.9];
        _body.shadowOffset = theme.isDark ? CGSizeMake(0, -1) : CGSizeMake(0, 1);
        [self.contentView addSubview:_body];
        _timeLabel = [[UILabel alloc] init];
        _timeLabel.font = [UIFont systemFontOfSize:11];
        _timeLabel.textColor = [theme secondaryTextColor];
        _timeLabel.backgroundColor = [UIColor clearColor];
        [theme embossLabel:_timeLabel];
        [self.contentView addSubview:_timeLabel];
    }
    return self;
}

- (void)configureWithComment:(SHComment *)comment
{
    _comment = comment;
    [_avatar setImageURL:comment.user.profilePicURL placeholder:[[SHTheme shared] avatarPlaceholderWithSize:SHCommentAvatar]];
    NSAttributedString *text = SHCommentText(comment);
    _body.attributedText = text;
    if (comment.user.username.length)
        [_body addUserLinkWithRange:NSMakeRange(0, comment.user.username.length) username:comment.user.username pk:comment.user.pk];
    _timeLabel.text = comment.createdAt ? [SHUtils formatRelativeDate:comment.createdAt] : @"";
    [self setNeedsLayout];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width - SHCommentTextX - 12;
    CGFloat h = [SHLinkLabel sizeForAttributedText:SHCommentText(_comment) width:w lines:0].height;
    _body.frame = CGRectMake(SHCommentTextX, 10, w, h);
    _timeLabel.frame = CGRectMake(SHCommentTextX, 10 + h + 3, w, 14);
}

- (void)avatarTapped
{
    if (_comment.user) [SHLinkRouter openProfileWithUsername:_comment.user.username pk:_comment.user.pk];
}

@end

@interface SHCommentsViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) SHPost *post;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *inputBar;
@property (nonatomic, strong) UITextField *textField;
@property (nonatomic, strong) NSMutableArray *comments;
@property (nonatomic, copy) NSString *nextMinId;
@property (nonatomic, strong) SHHTTPTask *task;
@property (nonatomic) BOOL loading;
@end

@implementation SHCommentsViewController

- (instancetype)initWithPost:(SHPost *)post
{
    if ((self = [super init])) { _post = post; _comments = [NSMutableArray array]; }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = L(@"Comments");
    self.view.backgroundColor = [[SHTheme shared] backgroundColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:L(@"Done")
        style:UIBarButtonItemStyleDone target:self action:@selector(dismissSelf)];

    CGFloat barH = 44;
    CGRect bounds = self.view.bounds;
    _tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, bounds.size.width, bounds.size.height - barH)
                                              style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [[SHTheme shared] applyToTableView:_tableView];
    [self.view addSubview:_tableView];

    _inputBar = [[UIView alloc] initWithFrame:CGRectMake(0, bounds.size.height - barH, bounds.size.width, barH)];
    _inputBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    _inputBar.backgroundColor = [[SHTheme shared] backgroundColor];
    UIImageView *barArt = [[UIImageView alloc] initWithImage:[[SHTheme shared] barBackgroundImage]];   // the glossy iOS 6 bar
    barArt.frame = _inputBar.bounds;
    barArt.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_inputBar addSubview:barArt];
    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, 0, bounds.size.width, 0.5)];
    sep.backgroundColor = [[SHTheme shared] separatorColor];
    sep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_inputBar addSubview:sep];

    // the same inset field and glossy accent button as the Direct input bar
    _textField = [[UITextField alloc] initWithFrame:CGRectMake(8, 6, bounds.size.width - 86, 32)];
    _textField.borderStyle = UITextBorderStyleNone;
    _textField.background = [[SHTheme shared] textFieldBackgroundImage];
    _textField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 32)];
    _textField.leftViewMode = UITextFieldViewModeAlways;
    _textField.placeholder = L(@"Add a comment...");
    _textField.font = [UIFont systemFontOfSize:15];
    _textField.textColor = [[SHTheme shared] inputTextColor];
    _textField.delegate = self;
    _textField.returnKeyType = UIReturnKeySend;
    _textField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_inputBar addSubview:_textField];

    UIButton *send = [UIButton buttonWithType:UIButtonTypeCustom];
    send.frame = CGRectMake(bounds.size.width - 72, 6, 64, 32);
    [send setTitle:L(@"Post") forState:UIControlStateNormal];
    [send setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    send.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [send setBackgroundImage:[[SHTheme shared] accentButtonImageHighlighted:NO disabled:NO] forState:UIControlStateNormal];
    [send setBackgroundImage:[[SHTheme shared] accentButtonImageHighlighted:YES disabled:NO] forState:UIControlStateHighlighted];
    [[SHTheme shared] embossButton:send];
    send.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [send addTarget:self action:@selector(sendTapped) forControlEvents:UIControlEventTouchUpInside];
    [_inputBar addSubview:send];
    [self.view addSubview:_inputBar];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbHide:) name:UIKeyboardWillHideNotification object:nil];

    [self loadComments:NO];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_task cancel];
}

- (void)dismissSelf { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)loadComments:(BOOL)more
{
    if (_loading) return;
    _loading = YES;
    [_task cancel];
    _task = [SHInstagram commentsForPost:_post.pk minId:more ? _nextMinId : nil completion:^(NSArray *comments, NSString *nextMinId, NSError *error) {
        self->_loading = NO;
        if (error) return;
        if (!more) [self->_comments removeAllObjects];
        [self->_comments addObjectsFromArray:comments];
        self->_nextMinId = nextMinId;
        [self->_tableView reloadData];
    }];
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_comments.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    SHCommentCell *cell = [tableView dequeueReusableCellWithIdentifier:@"C"];
    if (!cell) cell = [[SHCommentCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"C"];
    [[SHTheme shared] styleCell:cell];
    [cell configureWithComment:[_comments objectAtIndex:(NSUInteger)indexPath.row]];
    return cell;
}

// As tall as the comment needs (a long one is not cut off after two lines).
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    SHComment *c = [_comments objectAtIndex:(NSUInteger)indexPath.row];
    CGFloat w = tableView.bounds.size.width - SHCommentTextX - 12;
    CGFloat h = [SHLinkLabel sizeForAttributedText:SHCommentText(c) width:w lines:0].height;
    return MAX(SHCommentAvatar + 20, 10 + h + 3 + 14 + 10);
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ((NSUInteger)indexPath.row >= _comments.count - 3 && _nextMinId.length && !_loading) [self loadComments:YES];
}

#pragma mark - Send

- (BOOL)textFieldShouldReturn:(UITextField *)tf { [self sendTapped]; return NO; }

- (void)sendTapped
{
    NSString *text = [_textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) return;
    _textField.text = @"";
    [_textField resignFirstResponder];
    [SHInstagram postComment:text onPost:_post.pk completion:^(BOOL ok, NSError *err) {
        if (ok) [self loadComments:NO];
        else if (err) [SHUtils alertWithTitle:L(@"Comment") message:err.localizedDescription];
    }];
}

#pragma mark - Keyboard

- (void)kbShow:(NSNotification *)n
{
    CGRect kf = [[n.userInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat h = kf.size.height;
    CGRect f = _inputBar.frame;
    f.origin.y = self.view.bounds.size.height - h - f.size.height;
    _inputBar.frame = f;
    _tableView.frame = CGRectMake(0, 0, self.view.bounds.size.width, f.origin.y);
}

- (void)kbHide:(NSNotification *)n
{
    CGRect f = _inputBar.frame;
    f.origin.y = self.view.bounds.size.height - f.size.height;
    _inputBar.frame = f;
    _tableView.frame = CGRectMake(0, 0, self.view.bounds.size.width, f.origin.y);
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
