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
static const CGFloat SHStoryBarHeight = 96;

@interface SHFeedViewController () <UITableViewDataSource, UITableViewDelegate, SHFeedCellDelegate, SHStoryBarDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) SHStoryBarView *storyBar;
@property (nonatomic, strong) NSMutableArray *posts;
@property (nonatomic, copy) NSString *nextMaxId;
@property (nonatomic, strong) SHHTTPTask *feedTask;
@property (nonatomic, strong) SHHTTPTask *actionTask;
@property (nonatomic) BOOL loading;
@property (nonatomic) NSInteger autoPages;
@property (nonatomic) BOOL freshFeed;          // the network answered (until then the list may be the kept one)
// "Suggested for you": what Instagram shows when the followed accounts are quiet. Filled from the explore feed,
// as its own section under the timeline posts.
@property (nonatomic, strong) NSMutableArray *suggested;
@property (nonatomic, copy) NSString *suggestedMaxId;
@property (nonatomic) BOOL loadingSuggested;
@property (nonatomic) BOOL freshSuggested;
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
    SHTheme *theme = [SHTheme shared];
    // The name in script lettering in the bar, like the app of the iOS 6 days; the tab keeps its own "Home" item
    // (setting self.title would overwrite the tab bar item on iOS 6).
    self.navigationItem.title = @"Gramify";
    self.navigationItem.titleView = [theme logoTitleView];
    self.view.backgroundColor = [theme linenColor];
    _posts = [NSMutableArray array];
    _suggested = [NSMutableArray array];

    UIBarButtonItem *search = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSearch
                                target:self action:@selector(searchTapped)];
    UIBarButtonItem *settings = [[UIBarButtonItem alloc] initWithImage:[theme gearBarIcon] style:UIBarButtonItemStyleBordered
                                  target:self action:@selector(settingsTapped)];
    settings.accessibilityLabel = L(@"Settings");
    self.navigationItem.leftBarButtonItem = settings;
    self.navigationItem.rightBarButtonItem = search;

    _storyBar = [[SHStoryBarView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, SHStoryBarHeight)];
    _storyBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _storyBar.delegate = self;

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.tableHeaderView = _storyBar;
    [theme applyToTableView:_tableView];
    [self.view addSubview:_tableView];

    // While nothing is listed yet the screen says so instead of staying blank under the story bar.
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:[theme spinnerStyle]];
    _spinner.center = CGPointMake(self.view.bounds.size.width / 2, SHStoryBarHeight + 60);
    _spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    _spinner.hidesWhenStopped = YES;
    [self.view addSubview:_spinner];
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, SHStoryBarHeight + 44, self.view.bounds.size.width - 40, 40)];
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 2;
    _statusLabel.font = [UIFont boldSystemFontOfSize:15];
    _statusLabel.textColor = [theme secondaryTextColor];
    _statusLabel.backgroundColor = [UIColor clearColor];
    [theme embossLabel:_statusLabel];
    _statusLabel.hidden = YES;
    [self.view addSubview:_statusLabel];

    // What was here last time shows at once; the network freshens it right after.
    [SHInstagram cachedTimelineWithCompletion:^(NSArray *posts, NSString *next, NSError *error) {
        if (self->_freshFeed || !posts.count) return;
        [self->_posts setArray:posts];
        [self->_tableView reloadData];
        [self updateStatus];
    }];
    [SHInstagram cachedExploreWithCompletion:^(NSArray *posts, NSString *next, NSError *error) {
        if (self->_freshSuggested || !posts.count) return;
        [self->_suggested removeAllObjects];
        for (SHPost *p in posts) if (p.image.url.length) [self->_suggested addObject:p];
        [self->_tableView reloadData];
        [self updateStatus];
    }];

    [self loadFeed:NO];
    [self loadStories];
    // The followed accounts of this kind of account are often quiet: the suggestions load alongside the
    // timeline instead of after it (one more request, the same the app makes when it starts).
    [self loadSuggested:NO];
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
            [self updateStatus];
            return;
        }
        if (!more) { [self->_posts removeAllObjects]; self->_freshFeed = YES; }
        [self->_posts addObjectsFromArray:posts];
        self->_nextMaxId = nextMaxId;
        [self->_tableView reloadData];
        // A quiet timeline opens with "Suggested for you" demarcators and no media on its first page(s); a few
        // more pages are tried for real posts (capped) while the suggestions fill the screen.
        if (self->_posts.count == 0 && nextMaxId.length && self->_autoPages < 3) {
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
        if (!more) { [self->_suggested removeAllObjects]; self->_freshSuggested = YES; }
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

// The tray, then (one request) the stories of the circles that came without them; only circles with a story to
// show are kept, so no circle opens onto nothing.
- (void)loadStories
{
    [_storyTask cancel];
    _storyTask = [SHInstagram storiesTrayWithCompletion:^(NSArray *reels, NSError *error) {
        if (error) { SHLog(@"Stories error: %@", error.localizedDescription); return; }
        self->_storyTask = [SHInstagram fillStoryReels:reels completion:^(NSArray *viewable) {
            [self->_storyBar setReels:[self trayOrdered:viewable]];
        }];
    }];
}

// The app's order: people with something new first, the ones seen through at the end (each group as the tray
// gave it); the account's own story stays first. A tray fresh from Instagram can lag behind what was just watched
// here, so what this device remembers counts too.
- (NSArray *)trayOrdered:(NSArray *)reels
{
    NSString *me = [SHSettings userId] ?: @"";
    NSMutableArray *ordered = [NSMutableArray array];
    NSMutableArray *fresh = [NSMutableArray array];
    NSMutableArray *seen = [NSMutableArray array];
    for (SHStoryReel *r in reels) {
        [r applyRememberedSeen];
        if (me.length && [r.user.pk isEqualToString:me]) [ordered addObject:r];
        else if (r.seen) [seen addObject:r];
        else [fresh addObject:r];
    }
    [ordered addObjectsFromArray:fresh];
    [ordered addObjectsFromArray:seen];
    return ordered;
}

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _suggested.count ? 2 : 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)(section == 0 ? _posts.count : _suggested.count);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section { return section == 1 ? 24 : 0; }

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if (section != 1) return nil;
    // the gradient header of iOS 6 plain tables, with the title pressed into it
    UIImageView *header = [[UIImageView alloc] initWithImage:[[SHTheme shared] sectionHeaderBackgroundImage]];
    header.frame = CGRectMake(0, 0, tableView.bounds.size.width, 24);
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, tableView.bounds.size.width - 24, 24)];
    label.text = L(@"Suggested for you");
    label.font = [UIFont boldSystemFontOfSize:13];
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
    // shown at once (as the app does); taken back if Instagram says no
    BOOL willLike = !post.hasLiked;
    post.hasLiked = willLike;
    post.likeCount = MAX(0, post.likeCount + (willLike ? 1 : -1));
    if (cell.post == post) [cell configureWithPost:post];
    void (^done)(BOOL, NSError *) = ^(BOOL ok, NSError *err) {
        if (ok) return;
        post.hasLiked = !willLike;
        post.likeCount = MAX(0, post.likeCount + (willLike ? -1 : 1));
        if (cell.post == post) [cell configureWithPost:post];
    };
    if (willLike) [SHInstagram likePost:post.pk completion:done];
    else [SHInstagram unlikePost:post.pk completion:done];
}

- (void)feedCell:(SHFeedCell *)cell didTapSaveOnPost:(SHPost *)post
{
    BOOL willSave = !post.saved;
    post.saved = willSave;
    if (cell.post == post) [cell configureWithPost:post];
    void (^done)(BOOL, NSError *) = ^(BOOL ok, NSError *err) {
        if (ok) return;
        post.saved = !willSave;
        if (cell.post == post) [cell configureWithPost:post];
    };
    if (willSave) [SHInstagram savePost:post.pk completion:done];
    else [SHInstagram unsavePost:post.pk completion:done];
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
    SHStoryViewController *vc = [[SHStoryViewController alloc] initWithReels:_storyBar.reels startIndex:index];
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    __weak SHFeedViewController *weakSelf = self;
    // the picture at the top of the viewer opens the person's profile here, in the feed's navigation
    vc.onOpenProfile = ^(SHUser *user) {
        SHFeedViewController *strong = weakSelf;
        SHProfileViewController *profile = [[SHProfileViewController alloc] initWithUsername:user.username pk:user.pk];
        [strong.navigationController pushViewController:profile animated:YES];
    };
    // the circles just watched through go grey and move to the end
    vc.onClose = ^{
        SHFeedViewController *strong = weakSelf;
        [strong.storyBar setReels:[strong trayOrdered:strong.storyBar.reels]];
    };
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
        [self loadSuggested:NO];
    }
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
