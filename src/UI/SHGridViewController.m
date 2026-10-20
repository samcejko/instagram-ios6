#import "SHGridViewController.h"
#import "SHReelsViewController.h"
#import "SHGridRowCell.h"
#import "SHPostDetailViewController.h"
#import "SHModels.h"
#import "SHTheme.h"
#import "SHCommon.h"

static NSString * const SHGridCellId = @"GridRow";

@interface SHGridViewController () <UITableViewDataSource, UITableViewDelegate, SHGridRowDelegate>
@property (nonatomic, copy) SHGridLoader loader;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray *posts;
@property (nonatomic, copy) NSString *nextMaxId;
@property (nonatomic, strong) SHHTTPTask *task;
@property (nonatomic) BOOL loading;
@property (nonatomic) BOOL loadedOnce;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation SHGridViewController

- (instancetype)initWithTitle:(NSString *)title loader:(SHGridLoader)loader
{
    if ((self = [super init])) {
        self.title = title;
        _loader = [loader copy];
        _posts = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [[SHTheme shared] linenColor];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [[SHTheme shared] applyToTableView:_tableView];
    [self.view addSubview:_tableView];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 30, 0)];
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _statusLabel.numberOfLines = 0;
    _statusLabel.textAlignment = UITextAlignmentCenter;
    _statusLabel.font = [UIFont boldSystemFontOfSize:15];
    _statusLabel.textColor = [[SHTheme shared] secondaryTextColor];
    _statusLabel.backgroundColor = [UIColor clearColor];
    [[SHTheme shared] embossLabel:_statusLabel];
    _statusLabel.hidden = YES;
    [self.view addSubview:_statusLabel];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:[[SHTheme shared] spinnerStyle]];
    _spinner.center = CGPointMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2);
    _spinner.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    _spinner.hidesWhenStopped = YES;
    [self.view addSubview:_spinner];

    if (_secondaryTitle.length && _secondaryLoader) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:_secondaryTitle style:UIBarButtonItemStyleBordered
                                                                                  target:self action:@selector(showSecondary)];
    }
    [self loadMore:NO];
}

- (void)showSecondary
{
    if (_secondaryFullScreen) {
        SHReelsViewController *reels = [[SHReelsViewController alloc] initWithLoader:_secondaryLoader];
        reels.cachedLoader = _secondaryCachedLoader;
        reels.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:reels animated:YES completion:nil];
        return;
    }
    SHGridViewController *vc = [[SHGridViewController alloc] initWithTitle:_secondaryTitle loader:_secondaryLoader];
    vc.emptyMessage = L(@"Nothing here yet.");
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)dealloc { [_task cancel]; }

- (void)refresh { [self loadMore:NO]; }

- (void)loadMore:(BOOL)more
{
    if (_loading || !_loader) return;
    if (more && !_nextMaxId.length) return;
    _loading = YES;
    if (!_loadedOnce) { [_spinner startAnimating]; _statusLabel.hidden = YES; }
    [_task cancel];
    __weak SHGridViewController *weak = self;
    _task = _loader(more ? _nextMaxId : nil, ^(NSArray *posts, NSString *nextMaxId, NSError *error) {
        SHGridViewController *strong = weak;
        if (!strong) return;
        strong.loading = NO;
        strong.loadedOnce = YES;
        [strong.spinner stopAnimating];
        if (error) {
            if (strong.posts.count == 0) [strong showStatus:error.localizedDescription];
            return;
        }
        if (!more) [strong.posts removeAllObjects];
        [strong.posts addObjectsFromArray:posts];
        strong.nextMaxId = nextMaxId;
        if (strong.posts.count == 0) [strong showStatus:strong.emptyMessage ?: L(@"Nothing here yet.")];
        else strong.statusLabel.hidden = YES;
        [strong.tableView reloadData];
    });
}

- (void)showStatus:(NSString *)text
{
    _statusLabel.text = text;
    _statusLabel.hidden = NO;
}

#pragma mark - Table

- (NSInteger)rowsForWidth:(CGFloat)w { return (NSInteger)((_posts.count + [SHGridRowCell columns] - 1) / [SHGridRowCell columns]); }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return [self rowsForWidth:tableView.bounds.size.width];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return [SHGridRowCell rowHeightForWidth:tableView.bounds.size.width];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    SHGridRowCell *cell = [tableView dequeueReusableCellWithIdentifier:SHGridCellId];
    if (!cell) cell = [[SHGridRowCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:SHGridCellId];
    cell.delegate = self;
    NSUInteger cols = [SHGridRowCell columns];
    NSUInteger start = (NSUInteger)indexPath.row * cols;
    NSMutableArray *row = [NSMutableArray array];
    for (NSUInteger i = start; i < start + cols && i < _posts.count; i++) [row addObject:[_posts objectAtIndex:i]];
    [cell configureWithPosts:row];
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ((NSUInteger)indexPath.row >= (NSUInteger)[self rowsForWidth:tableView.bounds.size.width] - 2 && _nextMaxId.length && !_loading)
        [self loadMore:YES];
}

- (void)gridRow:(SHGridRowCell *)row didTapPost:(SHPost *)post
{
    SHPostDetailViewController *vc = [[SHPostDetailViewController alloc] initWithPost:post];
    [self.navigationController pushViewController:vc animated:YES];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
