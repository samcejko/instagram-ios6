#import "SHFollowRequestsViewController.h"
#import "SHProfileViewController.h"
#import "SHInstagram.h"
#import "SHModels.h"
#import "SHImageLoader.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHCommon.h"

// One person asking: the picture, the name, Confirm (the accent button) and Delete (the grey one).
@interface SHFollowRequestCell : UITableViewCell
@property (nonatomic, strong) SHImageView *avatar;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *fullNameLabel;
@property (nonatomic, strong) UIButton *confirmButton;
@property (nonatomic, strong) UIButton *deleteButton;
@property (nonatomic, copy) void (^onAnswer)(BOOL approve);
@end

@implementation SHFollowRequestCell

- (UIButton *)buttonWithTitle:(NSString *)title accent:(BOOL)accent action:(SEL)action
{
    SHTheme *theme = [SHTheme shared];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    if (accent) {
        [b setBackgroundImage:[theme accentButtonImageHighlighted:NO disabled:NO] forState:UIControlStateNormal];
        [b setBackgroundImage:[theme accentButtonImageHighlighted:YES disabled:NO] forState:UIControlStateHighlighted];
        [b setBackgroundImage:[theme accentButtonImageHighlighted:NO disabled:YES] forState:UIControlStateDisabled];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    } else {
        [b setBackgroundImage:[theme buttonImageHighlighted:NO] forState:UIControlStateNormal];
        [b setBackgroundImage:[theme buttonImageHighlighted:YES] forState:UIControlStateHighlighted];
        [b setTitleColor:[theme textColor] forState:UIControlStateNormal];
    }
    [theme embossButton:b];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:b];
    return b;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        SHTheme *theme = [SHTheme shared];
        _avatar = [[SHImageView alloc] initWithFrame:CGRectMake(12, 10, 44, 44)];
        [theme styleAvatar:_avatar radius:5];
        _avatar.maxPixels = 128;
        [self.contentView addSubview:_avatar];
        _nameLabel = [[UILabel alloc] init];
        _nameLabel.font = [UIFont boldSystemFontOfSize:15];
        _nameLabel.textColor = [theme textColor];
        _nameLabel.highlightedTextColor = [UIColor whiteColor];
        _nameLabel.backgroundColor = [UIColor clearColor];
        [theme embossLabel:_nameLabel];
        [self.contentView addSubview:_nameLabel];
        _fullNameLabel = [[UILabel alloc] init];
        _fullNameLabel.font = [UIFont systemFontOfSize:13];
        _fullNameLabel.textColor = [theme secondaryTextColor];
        _fullNameLabel.highlightedTextColor = [UIColor whiteColor];
        _fullNameLabel.backgroundColor = [UIColor clearColor];
        [theme embossLabel:_fullNameLabel];
        [self.contentView addSubview:_fullNameLabel];
        _confirmButton = [self buttonWithTitle:L(@"Confirm") accent:YES action:@selector(confirmTapped)];
        _deleteButton = [self buttonWithTitle:L(@"Delete") accent:NO action:@selector(deleteTapped)];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    UIFont *f = _confirmButton.titleLabel.font;
    CGFloat confirmW = MAX(84, [L(@"Confirm") sizeWithFont:f].width + 24);
    CGFloat deleteW = MAX(70, [L(@"Delete") sizeWithFont:f].width + 24);
    _deleteButton.frame = CGRectMake(w - 12 - deleteW, 16, deleteW, 32);
    _confirmButton.frame = CGRectMake(CGRectGetMinX(_deleteButton.frame) - 8 - confirmW, 16, confirmW, 32);
    CGFloat x = 66, right = CGRectGetMinX(_confirmButton.frame) - 8;
    _nameLabel.frame = CGRectMake(x, 13, right - x, 20);
    _fullNameLabel.frame = CGRectMake(x, 34, right - x, 17);
}

- (void)confirmTapped { if (_onAnswer) _onAnswer(YES); }
- (void)deleteTapped { if (_onAnswer) _onAnswer(NO); }

@end

@interface SHFollowRequestsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray *users;
@property (nonatomic, strong) NSMutableSet *answering;   // pks with an answer on its way
@property (nonatomic, strong) SHHTTPTask *task;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation SHFollowRequestsViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    SHTheme *theme = [SHTheme shared];
    self.title = L(@"Follow requests");
    self.view.backgroundColor = [theme linenColor];
    _users = [NSMutableArray array];
    _answering = [NSMutableSet set];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 64;
    [theme applyToTableView:_tableView];
    [self.view addSubview:_tableView];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 30, 0)];
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _statusLabel.numberOfLines = 0;
    _statusLabel.textAlignment = UITextAlignmentCenter;
    _statusLabel.font = [UIFont boldSystemFontOfSize:15];
    _statusLabel.textColor = [theme secondaryTextColor];
    _statusLabel.backgroundColor = [UIColor clearColor];
    [theme embossLabel:_statusLabel];
    _statusLabel.hidden = YES;
    [self.view addSubview:_statusLabel];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:[theme spinnerStyle]];
    _spinner.center = CGPointMake(self.view.bounds.size.width / 2, 80);
    _spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    _spinner.hidesWhenStopped = YES;
    [self.view addSubview:_spinner];
    [_spinner startAnimating];

    _task = [SHInstagram pendingFollowRequestsWithCompletion:^(NSArray *users, NSError *error) {
        [self->_spinner stopAnimating];
        if (error) { self->_statusLabel.text = error.localizedDescription; self->_statusLabel.hidden = NO; return; }
        [self->_users setArray:users];
        [self updateStatus];
        [self->_tableView reloadData];
    }];
}

- (void)dealloc { [_task cancel]; }

- (void)updateStatus
{
    _statusLabel.text = L(@"No requests.");
    _statusLabel.hidden = _users.count > 0;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_users.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    SHFollowRequestCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Req"];
    if (!cell) cell = [[SHFollowRequestCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Req"];
    [[SHTheme shared] styleCell:cell];
    SHUser *u = [_users objectAtIndex:(NSUInteger)indexPath.row];
    [cell.avatar setImageURL:u.profilePicURL placeholder:[[SHTheme shared] avatarPlaceholderWithSize:44]];
    cell.nameLabel.text = u.username;
    cell.fullNameLabel.text = [SHUtils displayText:u.fullName];
    BOOL busy = [_answering containsObject:u.pk ?: @""];
    cell.confirmButton.enabled = cell.deleteButton.enabled = !busy;
    __weak SHFollowRequestsViewController *weakSelf = self;
    cell.onAnswer = ^(BOOL approve) { [weakSelf answer:u approve:approve]; };
    [cell setNeedsLayout];
    return cell;
}

- (void)answer:(SHUser *)u approve:(BOOL)approve
{
    if (!u.pk.length || [_answering containsObject:u.pk]) return;
    [_answering addObject:u.pk];
    [_tableView reloadData];
    [SHInstagram answerFollowRequest:u.pk approve:approve completion:^(BOOL ok, NSError *error) {
        [self->_answering removeObject:u.pk];
        if (ok) {
            [self->_users removeObject:u];
            [self updateStatus];
            if (self.onChange) self.onChange();
        } else {
            [SHUtils alertWithTitle:L(@"Follow requests") message:error.localizedDescription];
        }
        [self->_tableView reloadData];
    }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SHUser *u = [_users objectAtIndex:(NSUInteger)indexPath.row];
    SHProfileViewController *vc = [[SHProfileViewController alloc] initWithUsername:u.username pk:u.pk];
    [self.navigationController pushViewController:vc animated:YES];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
