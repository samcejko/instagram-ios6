#import "SHFeedViewController.h"
#import "SHFeedCell.h"
#import "SHProfileViewController.h"
#import "SHStoryBarView.h"
#import "SHCommentsViewController.h"
#import "SHPostDetailViewController.h"
#import "SHSearchViewController.h"
#import "SHSettingsViewController.h"
#import "SHStoryViewController.h"
#import "SHInstagram.h"
#import "SHModels.h"
#import "SHSettings.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHMediaProxy.h"
#import "SHLinkRouter.h"
#import "SHCommon.h"

static NSString * const SHFeedCellId = @"FeedCell";

@interface SHFeedViewController () <UITableViewDataSource, UITableViewDelegate, SHFeedCellDelegate, SHStoryBarDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) SHStoryBarView *storyBar;
@property (nonatomic, strong) NSMutableArray *posts;
@property (nonatomic, copy) NSString *nextMaxId;
@property (nonatomic, strong) SHHTTPTask *feedTask;
@property (nonatomic, strong) SHHTTPTask *actionTask;
@property (nonatomic) BOOL loading;
@end

@implementation SHFeedViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Shutter";
    self.view.backgroundColor = [[SHTheme shared] backgroundColor];
    _posts = [NSMutableArray array];

    UIBarButtonItem *search = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSearch
                                target:self action:@selector(searchTapped)];
    UIBarButtonItem *settings = [[UIBarButtonItem alloc] initWithTitle:@"⚙" style:UIBarButtonItemStylePlain
                                  target:self action:@selector(settingsTapped)];
    settings.accessibilityLabel = L(@"Settings");
    self.navigationItem.leftBarButtonItem = settings;
    self.navigationItem.rightBarButtonItem = search;

    _storyBar = [[SHStoryBarView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 82)];
    _storyBar.delegate = self;

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    _tableView.tableHeaderView = _storyBar;
    [self.view addSubview:_tableView];

    [self loadFeed:NO];
    [self loadStories];
}

- (void)loadFeed:(BOOL)more
{
    if (_loading) return;
    _loading = YES;
    [_feedTask cancel];
    _feedTask = [SHInstagram timelineFeedWithMaxId:more ? _nextMaxId : nil completion:^(NSArray *posts, NSString *nextMaxId, NSError *error) {
        self->_loading = NO;
        if (error) { SHLog(@"Feed error: %@", error.localizedDescription); return; }
        if (!more) [self->_posts removeAllObjects];
        [self->_posts addObjectsFromArray:posts];
        self->_nextMaxId = nextMaxId;
        [self->_tableView reloadData];
    }];
}

- (void)loadStories
{
    [SHInstagram storiesTrayWithCompletion:^(NSArray *reels, NSError *error) {
        if (error) { SHLog(@"Stories error: %@", error.localizedDescription); return; }
        [self->_storyBar setReels:reels];
    }];
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)_posts.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    SHPost *post = _posts[(NSUInteger)indexPath.row];
    return [SHFeedCell heightForPost:post width:tableView.bounds.size.width];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    SHFeedCell *cell = [tableView dequeueReusableCellWithIdentifier:SHFeedCellId];
    if (!cell) cell = [[SHFeedCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:SHFeedCellId];
    cell.delegate = self;
    [cell configureWithPost:_posts[(NSUInteger)indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ((NSUInteger)indexPath.row >= _posts.count - 3 && _nextMaxId.length && !_loading) {
        [self loadFeed:YES];
    }
}

#pragma mark - SHFeedCellDelegate

- (void)feedCell:(SHFeedCell *)cell didTapUser:(NSString *)pk username:(NSString *)username
{
    SHProfileViewController *vc = [[SHProfileViewController alloc] initWithUsername:username pk:pk];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)feedCell:(SHFeedCell *)cell didTapLikeOnPost:(SHPost *)post
{
    [_actionTask cancel];
    BOOL willLike = !post.hasLiked;
    _actionTask = willLike
        ? [SHInstagram likePost:post.pk completion:^(BOOL ok, NSError *err) {
            if (ok) { post.hasLiked = YES; post.likeCount++; [cell configureWithPost:post]; }
          }]
        : [SHInstagram unlikePost:post.pk completion:^(BOOL ok, NSError *err) {
            if (ok) { post.hasLiked = NO; post.likeCount = MAX(0, post.likeCount - 1); [cell configureWithPost:post]; }
          }];
}

- (void)feedCell:(SHFeedCell *)cell didTapCommentOnPost:(SHPost *)post
{
    SHCommentsViewController *vc = [[SHCommentsViewController alloc] initWithPost:post];
    [SHLinkRouter presentInNavigation:vc];
}

- (void)feedCell:(SHFeedCell *)cell didTapImageOnPost:(SHPost *)post
{
    SHPostDetailViewController *vc = [[SHPostDetailViewController alloc] initWithPost:post];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - SHStoryBarDelegate

- (void)storyBar:(SHStoryBarView *)bar didSelectReel:(SHStoryReel *)reel atIndex:(NSUInteger)index
{
    NSMutableArray *pks = [NSMutableArray array];
    for (SHStoryReel *r in _storyBar.reels) [pks addObject:r.user.pk];
    [SHInstagram storiesForUserPks:pks completion:^(NSArray *reels, NSError *error) {
        if (error || !reels.count) return;
        SHStoryViewController *vc = [[SHStoryViewController alloc] initWithReels:reels startIndex:index];
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:vc animated:YES completion:nil];
    }];
}

#pragma mark - Actions

- (void)searchTapped
{
    SHSearchViewController *vc = [[SHSearchViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)settingsTapped
{
    SHSettingsViewController *vc = [[SHSettingsViewController alloc] init];
    [SHLinkRouter presentInNavigation:vc];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    if (scrollView.contentOffset.y < -60) {
        [self loadFeed:NO];
        [self loadStories];
    }
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
