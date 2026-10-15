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
@property (nonatomic) NSInteger autoPages;
// "Suggested for you": what Instagram shows when the followed accounts are quiet. Filled from the explore feed
// once the timeline runs dry, as its own section under the timeline posts.
@property (nonatomic, strong) NSMutableArray *suggested;
@property (nonatomic, copy) NSString *suggestedMaxId;
@property (nonatomic) BOOL loadingSuggested;
@property (nonatomic, strong) SHHTTPTask *suggestedTask;
@property (nonatomic, strong) SHHTTPTask *storyTask;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;   // under the story bar while the list is still empty
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic) BOOL failed;
@end

@implementation SHFeedViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    // The brand name belongs in the navigation bar; the tab keeps its own "Home" item (setting self.title would
    // overwrite the tab bar item on iOS 6).
    self.navigationItem.title = @"Gramify";
    self.view.backgroundColor = [[SHTheme shared] backgroundColor];
    _posts = [NSMutableArray array];
    _suggested = [NSMutableArray array];

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
    [[SHTheme shared] applyToTableView:_tableView];
    _tableView.backgroundColor = [[SHTheme shared] backgroundColor];
    [self.view addSubview:_tableView];

    // While nothing is listed yet the screen says so instead of staying blank under the story bar.
    CGFloat storyH = _storyBar.bounds.size.height;
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:[[SHTheme shared] isDark] ? UIActivityIndicatorViewStyleWhite : UIActivityIndicatorViewStyleGray];
    _spinner.center = CGPointMake(self.view.bounds.size.width / 2, storyH + 60);
    _spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    _spinner.hidesWhenStopped = YES;
    [self.view addSubview:_spinner];
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, storyH + 44, self.view.bounds.size.width - 40, 40)];
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 2;
    _statusLabel.font = [UIFont systemFontOfSize:15];
    _statusLabel.textColor = [[SHTheme shared] secondaryTextColor];
    _statusLabel.backgroundColor = [UIColor clearColor];
    _statusLabel.hidden = YES;
    [self.view addSubview:_statusLabel];

    [self loadFeed:NO];
    [self loadStories];
}

- (void)updateStatus
{
    BOOL empty = _posts.count == 0 && _suggested.count == 0;
    BOOL busy = _loading || _loadingSuggested;
    if (empty && busy) [_spinner startAnimating]; else [_spinner stopAnimating];
    _statusLabel.text = _failed ? L(@"Couldn't load the feed.") : L(@"Nothing here yet.");
    _statusLabel.hidden = !(empty && !busy);
}

- (void)loadFeed:(BOOL)more
{
    if (_loading) return;
    _loading = YES;
    if (!more) { _autoPages = 0; _failed = NO; }
    [self updateStatus];
    [_feedTask cancel];
    _feedTask = [SHInstagram timelineFeedWithMaxId:more ? _nextMaxId : nil completion:^(NSArray *posts, NSString *nextMaxId, NSError *error) {
        self->_loading = NO;
        if (error) {
            SHLog(@"Feed error: %@", error.localizedDescription);
            self->_failed = self->_posts.count == 0;
            if (self->_suggested.count == 0) [self loadSuggested:NO];   // suggestions still give something to look at
            [self updateStatus];
            return;
        }
        if (!more) [self->_posts removeAllObjects];
        [self->_posts addObjectsFromArray:posts];
        self->_nextMaxId = nextMaxId;
        [self->_tableView reloadData];
        // A quiet timeline opens with "Suggested for you" demarcators and no media on its first page(s). The
        // suggested posts are fetched at once, so the screen fills while a few more pages are tried for real posts
        // (capped), instead of after them. A refresh renews the suggestions too.
        if (self->_posts.count < 3 && (self->_suggested.count == 0 || !more)) [self loadSuggested:NO];
        if (self->_posts.count == 0 && nextMaxId.length && self->_autoPages < 4) {
            self->_autoPages++;
            [self loadFeed:YES];
        }
        [self updateStatus];
    }];
}

- (void)loadSuggested:(BOOL)more
{
    if (_loadingSuggested) return;
    if (more && !_suggestedMaxId.length) return;
    _loadingSuggested = YES;
    [self updateStatus];
    [_suggestedTask cancel];
    _suggestedTask = [SHInstagram exploreWithMaxId:more ? _suggestedMaxId : nil completion:^(NSArray *posts, NSString *nextMaxId, NSError *error) {
        self->_loadingSuggested = NO;
        if (error) { SHLog(@"Suggested error: %@", error.localizedDescription); [self updateStatus]; return; }
        if (!more) [self->_suggested removeAllObjects];
        for (SHPost *p in posts) if (p.image.url.length) [self->_suggested addObject:p];
        self->_suggestedMaxId = nextMaxId;
        [self->_tableView reloadData];
        [self updateStatus];
    }];
}

- (SHPost *)postAt:(NSIndexPath *)ip
{
    NSArray *src = ip.section == 0 ? _posts : _suggested;
    return (NSUInteger)ip.row < src.count ? src[(NSUInteger)ip.row] : nil;
}

- (void)loadStories
{
    [SHInstagram storiesTrayWithCompletion:^(NSArray *reels, NSError *error) {
        if (error) { SHLog(@"Stories error: %@", error.localizedDescription); return; }
        [self->_storyBar setReels:reels];
    }];
}

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _suggested.count ? 2 : 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)(section == 0 ? _posts.count : _suggested.count);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section { return section == 1 ? 26 : 0; }

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if (section != 1) return nil;
    // the blue-grey gradient header of iOS 6 plain tables, with the title pressed into it
    UIImageView *header = [[UIImageView alloc] initWithImage:[[SHTheme shared] sectionHeaderBackgroundImage]];
    header.frame = CGRectMake(0, 0, tableView.bounds.size.width, 26);
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, tableView.bounds.size.width - 24, 26)];
    label.text = L(@"Suggested for you");
    label.font = [[SHTheme shared] tinyBoldFont];
    label.textColor = [[SHTheme shared] embossTextColor];
    label.backgroundColor = [UIColor clearColor];
    [[SHTheme shared] embossLabel:label];
    [header addSubview:label];
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    SHPost *post = [self postAt:indexPath];
    return post ? [SHFeedCell heightForPost:post width:tableView.bounds.size.width] : 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    SHFeedCell *cell = [tableView dequeueReusableCellWithIdentifier:SHFeedCellId];
    if (!cell) cell = [[SHFeedCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:SHFeedCellId];
    cell.delegate = self;
    [cell configureWithPost:[self postAt:indexPath]];
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        if ((NSUInteger)indexPath.row + 3 >= _posts.count && _nextMaxId.length && !_loading) [self loadFeed:YES];
    } else {
        if ((NSUInteger)indexPath.row + 3 >= _suggested.count && _suggestedMaxId.length && !_loadingSuggested) [self loadSuggested:YES];
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
    // The tray carries the items of the first reels only; the viewer fetches the others as it reaches them, so a
    // tap opens at once and swiping on through the tray keeps working.
    SHStoryViewController *vc = [[SHStoryViewController alloc] initWithReels:_storyBar.reels startIndex:index];
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:vc animated:YES completion:nil];
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
