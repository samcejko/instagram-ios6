#import "SHUserListViewController.h"
#import "SHProfileViewController.h"
#import "SHImageLoader.h"
#import "SHModels.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHCommon.h"

static NSString * const SHUserCellId = @"UserCell";

@interface SHUserRowCell : UITableViewCell
@property (nonatomic, strong) SHImageView *avatar;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *fullLabel;
@end

@implementation SHUserRowCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        _avatar = [[SHImageView alloc] initWithFrame:CGRectMake(12, 9, 40, 40)];
        _avatar.layer.cornerRadius = 20;
        _avatar.clipsToBounds = YES;
        _avatar.backgroundColor = [[SHTheme shared] separatorColor];
        [self.contentView addSubview:_avatar];
        _nameLabel = [[UILabel alloc] init];
        _nameLabel.font = [UIFont boldSystemFontOfSize:14];
        _nameLabel.textColor = [[SHTheme shared] textColor];
        _nameLabel.backgroundColor = [UIColor clearColor];
        [self.contentView addSubview:_nameLabel];
        _fullLabel = [[UILabel alloc] init];
        _fullLabel.font = [UIFont systemFontOfSize:12];
        _fullLabel.textColor = [[SHTheme shared] secondaryTextColor];
        _fullLabel.backgroundColor = [UIColor clearColor];
        [self.contentView addSubview:_fullLabel];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat x = 62, w = self.contentView.bounds.size.width - x - 12;
    BOOL hasFull = _fullLabel.text.length > 0;
    if (hasFull) {
        _nameLabel.frame = CGRectMake(x, 11, w, 20);
        _fullLabel.frame = CGRectMake(x, 31, w, 16);
    } else {
        _nameLabel.frame = CGRectMake(x, 19, w, 20);
    }
    _fullLabel.hidden = !hasFull;
}

@end

@interface SHUserListViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, copy) SHUserListLoader loader;
@property (nonatomic, strong) NSMutableArray *users;
@property (nonatomic, copy) NSString *nextMaxId;
@property (nonatomic, copy) NSString *query;
@property (nonatomic) BOOL searchable;
@property (nonatomic) BOOL loading;
@property (nonatomic) BOOL done;
@property (nonatomic, strong) id task;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchBar *searchBar;
@end

@implementation SHUserListViewController

- (instancetype)initWithTitle:(NSString *)title loader:(SHUserListLoader)loader searchable:(BOOL)searchable
{
    if ((self = [super init])) {
        self.title = title;
        _loader = [loader copy];
        _searchable = searchable;
        _users = [NSMutableArray array];
    }
    return self;
}

- (instancetype)initWithTitle:(NSString *)title users:(NSArray *)users
{
    if ((self = [super init])) {
        self.title = title;
        _users = users.count ? [users mutableCopy] : [NSMutableArray array];
        _done = YES;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [[SHTheme shared] backgroundColor];

    CGFloat top = 0;
    if (_searchable) {
        _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
        _searchBar.delegate = self;
        _searchBar.placeholder = L(@"Search");
        _searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [[SHTheme shared] applyToSearchBar:_searchBar];
        [self.view addSubview:_searchBar];
        top = 44;
    }

    _tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, top, self.view.bounds.size.width, self.view.bounds.size.height - top) style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 58;
    [[SHTheme shared] applyToTableView:_tableView];
    [self.view addSubview:_tableView];

    if (_loader) [self loadMore:NO];
    else [_tableView reloadData];
}

- (void)loadMore:(BOOL)more
{
    if (_loading || !_loader) return;
    if (more && (_done || !_nextMaxId.length)) return;
    _loading = YES;
    __weak SHUserListViewController *weak = self;
    _task = _loader(more ? _nextMaxId : nil, _query, ^(NSArray *users, NSString *nextMaxId, NSError *error) {
        SHUserListViewController *strong = weak;
        if (!strong) return;
        strong.loading = NO;
        if (error) return;
        if (!more) [strong.users removeAllObjects];
        [strong.users addObjectsFromArray:users];
        strong.nextMaxId = nextMaxId;
        strong.done = nextMaxId.length == 0;
        [strong.tableView reloadData];
    });
}

#pragma mark - Search

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
    _query = searchText;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(runSearch) object:nil];
    [self performSelector:@selector(runSearch) withObject:nil afterDelay:0.4];
}

- (void)runSearch { _done = NO; _nextMaxId = nil; [self loadMore:NO]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; }

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_users.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    SHUserRowCell *cell = [tableView dequeueReusableCellWithIdentifier:SHUserCellId];
    if (!cell) cell = [[SHUserRowCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:SHUserCellId];
    SHUser *u = _users[(NSUInteger)indexPath.row];
    [cell.avatar setImageURL:u.profilePicURL placeholder:nil];
    cell.nameLabel.text = u.isVerified ? [u.username stringByAppendingString:@" ✓"] : u.username;
    cell.fullLabel.text = u.fullName;
    [[SHTheme shared] styleCell:cell];
    [cell setNeedsLayout];
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ((NSUInteger)indexPath.row >= _users.count - 5 && !_done && !_loading) [self loadMore:YES];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SHUser *u = _users[(NSUInteger)indexPath.row];
    SHProfileViewController *vc = [[SHProfileViewController alloc] initWithUsername:u.username pk:u.pk];
    [self.navigationController pushViewController:vc animated:YES];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
