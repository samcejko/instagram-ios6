#import "SHInboxViewController.h"
#import "SHThreadViewController.h"
#import "SHProfileViewController.h"
#import "SHInstagram.h"
#import "SHModels.h"
#import "SHImageLoader.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHCommon.h"

static NSString * const SHThreadCellId = @"ThreadCell";

@interface SHThreadRowCell : UITableViewCell
@property (nonatomic, strong) SHImageView *avatar;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *previewLabel;
@property (nonatomic, strong) UIImageView *unreadDot;
@property (nonatomic, copy) void (^onAvatarTap)(void);   // tapping the picture opens that person's profile
@end

@implementation SHThreadRowCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        SHTheme *theme = [SHTheme shared];
        _avatar = [[SHImageView alloc] initWithFrame:CGRectMake(12, 11, 50, 50)];
        [theme styleAvatar:_avatar radius:5];
        _avatar.maxPixels = 128;
        _avatar.userInteractionEnabled = YES;
        [_avatar addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(avatarTapped)]];
        [self.contentView addSubview:_avatar];
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont boldSystemFontOfSize:15];
        _titleLabel.textColor = [theme textColor];
        _titleLabel.highlightedTextColor = [UIColor whiteColor];
        _titleLabel.backgroundColor = [UIColor clearColor];
        [theme embossLabel:_titleLabel];
        [self.contentView addSubview:_titleLabel];
        _previewLabel = [[UILabel alloc] init];
        _previewLabel.font = [UIFont systemFontOfSize:13];
        _previewLabel.textColor = [theme secondaryTextColor];
        _previewLabel.highlightedTextColor = [UIColor whiteColor];
        _previewLabel.backgroundColor = [UIColor clearColor];
        [theme embossLabel:_previewLabel];
        [self.contentView addSubview:_previewLabel];
        _unreadDot = [[UIImageView alloc] initWithImage:[theme unreadDotImage]];
        _unreadDot.hidden = YES;
        [self.contentView addSubview:_unreadDot];
        self.accessoryView = [[UIImageView alloc] initWithImage:[theme disclosureChevronImage]];
    }
    return self;
}
- (void)avatarTapped { if (_onAvatarTap) _onAvatarTap(); }

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width, x = 74;
    _titleLabel.frame = CGRectMake(x, 15, w - x - 30, 21);
    _previewLabel.frame = CGRectMake(x, 38, w - x - 30, 18);
    _unreadDot.frame = CGRectMake(w - 20, 30, 12, 12);
}
@end

@interface SHInboxViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray *threads;
@property (nonatomic, copy) NSString *cursor;
@property (nonatomic, strong) SHHTTPTask *task;
@property (nonatomic) BOOL loading;
@property (nonatomic) BOOL fresh;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation SHInboxViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    SHTheme *theme = [SHTheme shared];
    self.title = L(@"Direct");
    self.view.backgroundColor = [theme linenColor];
    _threads = [NSMutableArray array];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 72;
    [theme applyToTableView:_tableView];
    [self.view addSubview:_tableView];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 30, 0)];
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _statusLabel.numberOfLines = 0;
    _statusLabel.textAlignment = NSTextAlignmentCenter;
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

    // the conversations of last time at once; the network freshens them when the tab shows
    [SHInstagram cachedDirectInboxWithCompletion:^(NSArray *threads, NSString *cursor, NSError *error) {
        if (self->_fresh || !threads.count) return;
        [self->_threads setArray:threads];
        [self->_spinner stopAnimating];
        [self->_tableView reloadData];
    }];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self load:NO];   // refresh each time the tab is shown
}

- (void)dealloc { [_task cancel]; }

- (void)load:(BOOL)more
{
    if (_loading) return;
    if (more && !_cursor.length) return;
    _loading = YES;
    if (_threads.count == 0) [_spinner startAnimating];
    [_task cancel];
    _task = [SHInstagram directInboxWithCursor:more ? _cursor : nil completion:^(NSArray *threads, NSString *cursor, NSError *error) {
        self->_loading = NO;
        [self->_spinner stopAnimating];
        if (error) {
            if (self->_threads.count == 0) { self->_statusLabel.text = error.localizedDescription; self->_statusLabel.hidden = NO; }
            return;
        }
        if (!more) { [self->_threads removeAllObjects]; self->_fresh = YES; }
        [self->_threads addObjectsFromArray:threads];
        self->_cursor = cursor;
        self->_statusLabel.hidden = self->_threads.count > 0;
        if (self->_threads.count == 0) { self->_statusLabel.text = L(@"No messages yet."); self->_statusLabel.hidden = NO; }
        [self->_tableView reloadData];
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_threads.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    SHThreadRowCell *cell = [tableView dequeueReusableCellWithIdentifier:SHThreadCellId];
    if (!cell) cell = [[SHThreadRowCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:SHThreadCellId];
    [[SHTheme shared] styleCell:cell];
    SHDirectThread *t = _threads[(NSUInteger)indexPath.row];
    SHUser *first = [t.users firstObject];
    [cell.avatar setImageURL:first.profilePicURL placeholder:[[SHTheme shared] avatarPlaceholderWithSize:50]];
    __weak SHInboxViewController *weakSelf = self;
    cell.onAvatarTap = ^{
        if (!first.username.length && !first.pk.length) return;
        SHProfileViewController *vc = [[SHProfileViewController alloc] initWithUsername:first.username pk:first.pk];
        [weakSelf.navigationController pushViewController:vc animated:YES];
    };
    cell.titleLabel.text = [SHUtils displayText:t.title];
    cell.previewLabel.text = [SHUtils displayText:t.lastText ?: @""];
    cell.unreadDot.hidden = !t.unread;
    cell.previewLabel.textColor = t.unread ? [[SHTheme shared] textColor] : [[SHTheme shared] secondaryTextColor];
    [cell setNeedsLayout];
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ((NSUInteger)indexPath.row + 3 >= _threads.count && _cursor.length && !_loading) [self load:YES];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SHDirectThread *t = _threads[(NSUInteger)indexPath.row];
    SHThreadViewController *vc = [[SHThreadViewController alloc] initWithThread:t];
    [self.navigationController pushViewController:vc animated:YES];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
