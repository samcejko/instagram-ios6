#import "SHCommentsViewController.h"
#import "SHInstagram.h"
#import "SHModels.h"
#import "SHImageLoader.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHCommon.h"

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
    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, 0, bounds.size.width, 0.5)];
    sep.backgroundColor = [[SHTheme shared] separatorColor];
    sep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_inputBar addSubview:sep];

    _textField = [[UITextField alloc] initWithFrame:CGRectMake(12, 6, bounds.size.width - 80, 32)];
    _textField.borderStyle = UITextBorderStyleRoundedRect;
    _textField.placeholder = L(@"Add a comment...");
    _textField.font = [UIFont systemFontOfSize:14];
    _textField.delegate = self;
    _textField.returnKeyType = UIReturnKeySend;
    _textField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_inputBar addSubview:_textField];

    UIButton *send = [UIButton buttonWithType:UIButtonTypeCustom];
    send.frame = CGRectMake(bounds.size.width - 64, 6, 56, 32);
    [send setTitle:L(@"Post") forState:UIControlStateNormal];
    [send setTitleColor:[[SHTheme shared] linkColor] forState:UIControlStateNormal];
    send.titleLabel.font = [UIFont boldSystemFontOfSize:14];
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
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"C"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"C"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.font = [UIFont systemFontOfSize:13];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
        cell.detailTextLabel.textColor = [[SHTheme shared] secondaryTextColor];
    }
    [[SHTheme shared] styleCell:cell];
    SHComment *c = _comments[(NSUInteger)indexPath.row];
    UIColor *tc = [[SHTheme shared] textColor];
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] init];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:[c.user.username stringByAppendingString:@" "]
        attributes:@{ NSFontAttributeName: [UIFont boldSystemFontOfSize:13], NSForegroundColorAttributeName: tc }]];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:[SHUtils displayText:c.text]
        attributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: tc }]];
    cell.textLabel.attributedText = text;
    cell.detailTextLabel.text = c.createdAt ? [SHUtils formatRelativeDate:c.createdAt] : @"";
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath { return 60; }

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
    CGRect kf = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
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
