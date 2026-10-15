#import "SHInboxViewController.h"
#import "SHThreadViewController.h"
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
@property (nonatomic, strong) UIView *unreadDot;
@end

@implementation SHThreadRowCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        _avatar = [[SHImageView alloc] initWithFrame:CGRectMake(12, 12, 48, 48)];
        _avatar.layer.cornerRadius = 24;
        _avatar.clipsToBounds = YES;
        _avatar.backgroundColor = [[SHTheme shared] separatorColor];
        [self.contentView addSubview:_avatar];
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont boldSystemFontOfSize:14];
        _titleLabel.textColor = [[SHTheme shared] textColor];
        _titleLabel.backgroundColor = [UIColor clearColor];
        [self.contentView addSubview:_titleLabel];
        _previewLabel = [[UILabel alloc] init];
        _previewLabel.font = [UIFont systemFontOfSize:12];
        _previewLabel.textColor = [[SHTheme shared] secondaryTextColor];
        _previewLabel.backgroundColor = [UIColor clearColor];
        [self.contentView addSubview:_previewLabel];
        _unreadDot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 8)];
        _unreadDot.backgroundColor = [SHUtils colorFromHex:@"#0095F6"];
        _unreadDot.layer.cornerRadius = 4;
        _unreadDot.hidden = YES;
        [self.contentView addSubview:_unreadDot];
    }
    return self;
}
- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width, x = 70;
    _titleLabel.frame = CGRectMake(x, 16, w - x - 28, 20);
    _previewLabel.frame = CGRectMake(x, 38, w - x - 28, 18);
    _unreadDot.frame = CGRectMake(w - 24, 34, 8, 8);
}
@end

@interface SHInboxViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray *threads;
@property (nonatomic, copy) NSString *cursor;
@property (nonatomic, strong) SHHTTPTask *task;
@property (nonatomic) BOOL loading;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation SHInboxViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = L(@"Direct");
    self.view.backgroundColor = [[SHTheme shared] backgroundColor];
    _threads = [NSMutableArray array];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 72;
    [[SHTheme shared] applyToTableView:_tableView];
    [self.view addSubview:_tableView];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 30, 0)];
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _statusLabel.numberOfLines = 0;
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.font = [UIFont systemFontOfSize:14];
    _statusLabel.textColor = [[SHTheme shared] secondaryTextColor];
    _statusLabel.hidden = YES;
    [self.view addSubview:_statusLabel];
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
    [_task cancel];
    _task = [SHInstagram directInboxWithCursor:more ? _cursor : nil completion:^(NSArray *threads, NSString *cursor, NSError *error) {
        self->_loading = NO;
        if (error) {
            if (self->_threads.count == 0) { self->_statusLabel.text = error.localizedDescription; self->_statusLabel.hidden = NO; }
            return;
        }
        if (!more) [self->_threads removeAllObjects];
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
    SHDirectThread *t = _threads[(NSUInteger)indexPath.row];
    SHUser *first = [t.users firstObject];
    [cell.avatar setImageURL:first.profilePicURL placeholder:nil];
    cell.titleLabel.text = t.title;
    cell.previewLabel.text = [SHUtils displayText:t.lastText ?: @""];
    cell.unreadDot.hidden = !t.unread;
    cell.titleLabel.font = t.unread ? [UIFont boldSystemFontOfSize:14] : [UIFont systemFontOfSize:14];
    [[SHTheme shared] styleCell:cell];
    [cell setNeedsLayout];
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ((NSUInteger)indexPath.row >= _threads.count - 3 && _cursor.length && !_loading) [self load:YES];
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
