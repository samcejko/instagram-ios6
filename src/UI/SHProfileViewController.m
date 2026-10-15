#import "SHProfileViewController.h"
#import "SHGridRowCell.h"
#import "SHGridViewController.h"
#import "SHUserListViewController.h"
#import "SHPostDetailViewController.h"
#import "SHSettingsViewController.h"
#import "SHInstagram.h"
#import "SHModels.h"
#import "SHImageLoader.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHSettings.h"
#import "SHLinkRouter.h"
#import "SHCommon.h"

@interface SHProfileViewController () <UITableViewDataSource, UITableViewDelegate, SHGridRowDelegate>
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *pk;
@property (nonatomic, strong) SHUser *user;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) NSMutableArray *posts;
@property (nonatomic, copy) NSString *nextMaxId;
@property (nonatomic, strong) SHHTTPTask *task;
@property (nonatomic, strong) SHHTTPTask *postsTask;
@property (nonatomic) BOOL loadingPosts;
@property (nonatomic, strong) UILabel *statusLabel;
@end

static NSString * const SHProfileGridId = @"ProfileGridRow";

@implementation SHProfileViewController

- (instancetype)initWithUsername:(NSString *)username pk:(NSString *)pk
{
    if ((self = [super init])) {
        _username = username;
        _pk = pk;
        _posts = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    // Put the username in the nav bar, not self.title, so the Profile tab keeps its "Profil" item.
    self.navigationItem.title = _username.length ? _username : L(@"Profile");
    self.view.backgroundColor = [[SHTheme shared] backgroundColor];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [[SHTheme shared] applyToTableView:_tableView];
    [self.view addSubview:_tableView];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 240, self.view.bounds.size.width - 40, 60)];
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _statusLabel.numberOfLines = 0;
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.font = [UIFont systemFontOfSize:14];
    _statusLabel.textColor = [[SHTheme shared] secondaryTextColor];
    _statusLabel.hidden = YES;
    [self.view addSubview:_statusLabel];

    if (_isCurrentUser) {
        UIBarButtonItem *gear = [[UIBarButtonItem alloc] initWithTitle:@"⚙" style:UIBarButtonItemStylePlain target:self action:@selector(settingsTapped)];
        gear.accessibilityLabel = L(@"Settings");
        self.navigationItem.rightBarButtonItem = gear;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionChanged) name:SHSettingsDidChangeNotification object:nil];
    }

    [self loadProfile];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; [_task cancel]; [_postsTask cancel]; }

- (void)sessionChanged
{
    if (![SHSettings isLoggedIn]) return;   // logout is handled by the app delegate switching to the login screen
}

- (void)loadProfile
{
    [_task cancel];
    void (^gotUser)(SHUser *, NSError *) = ^(SHUser *user, NSError *error) {
        if (error) {
            self->_statusLabel.text = error.localizedDescription;
            self->_statusLabel.hidden = NO;
            return;
        }
        self->_user = user;
        if (!self->_pk.length) self->_pk = user.pk;
        if (!self->_username.length) self->_username = user.username;
        self.navigationItem.title = user.username ?: self->_username;
        [self buildHeader];
        [self loadPosts:NO];
    };
    if (_isCurrentUser && !_pk.length && !_username.length) {
        _task = [SHInstagram currentUserWithCompletion:gotUser];
    } else if (_pk.length) {
        _task = [SHInstagram userInfoByPk:_pk completion:gotUser];
    } else if (_username.length) {
        _task = [SHInstagram userInfoByUsername:_username completion:gotUser];
    } else {
        _task = [SHInstagram currentUserWithCompletion:gotUser];
    }
}

- (UIButton *)statButton:(NSString *)number title:(NSString *)title frame:(CGRect)frame action:(SEL)action
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = frame;
    if (action) [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    UILabel *num = [[UILabel alloc] initWithFrame:CGRectMake(0, 4, frame.size.width, 20)];
    num.text = number;
    num.font = [UIFont boldSystemFontOfSize:16];
    num.textColor = [[SHTheme shared] textColor];
    num.textAlignment = NSTextAlignmentCenter;
    num.backgroundColor = [UIColor clearColor];
    [b addSubview:num];
    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(0, 24, frame.size.width, 16)];
    sub.text = title;
    sub.font = [UIFont systemFontOfSize:11];
    sub.textColor = [[SHTheme shared] secondaryTextColor];
    sub.textAlignment = NSTextAlignmentCenter;
    sub.backgroundColor = [UIColor clearColor];
    [b addSubview:sub];
    return b;
}

- (void)buildHeader
{
    CGFloat w = self.view.bounds.size.width;
    CGFloat pad = 16;
    _headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 180)];

    SHImageView *avatar = [[SHImageView alloc] initWithFrame:CGRectMake(pad, pad, 72, 72)];
    avatar.layer.cornerRadius = 36;
    avatar.clipsToBounds = YES;
    avatar.backgroundColor = [[SHTheme shared] separatorColor];
    [avatar setImageURL:_user.profilePicURL placeholder:nil];
    [_headerView addSubview:avatar];

    CGFloat statsX = pad + 72 + 12;
    CGFloat statsW = (w - statsX - pad) / 3;
    [_headerView addSubview:[self statButton:[SHUtils formatCount:_user.mediaCount] title:L(@"Posts")
                                       frame:CGRectMake(statsX, pad + 6, statsW, 44) action:nil]];
    [_headerView addSubview:[self statButton:[SHUtils formatCount:_user.followerCount] title:L(@"Followers")
                                       frame:CGRectMake(statsX + statsW, pad + 6, statsW, 44) action:@selector(showFollowers)]];
    [_headerView addSubview:[self statButton:[SHUtils formatCount:_user.followingCount] title:L(@"Following")
                                       frame:CGRectMake(statsX + statsW * 2, pad + 6, statsW, 44) action:@selector(showFollowing)]];

    CGFloat y = pad + 80;
    NSString *displayName = [SHUtils displayText:_user.fullName.length ? _user.fullName : _user.username];
    if (_user.isVerified) displayName = [displayName stringByAppendingString:@" ✓"];
    if (displayName.length) {
        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w - pad * 2, 20)];
        name.text = displayName;
        name.font = [UIFont boldSystemFontOfSize:14];
        name.textColor = [[SHTheme shared] textColor];
        name.backgroundColor = [UIColor clearColor];
        [_headerView addSubview:name];
        y += 20;
    }
    if (_user.biography.length) {
        UILabel *bio = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w - pad * 2, 0)];
        bio.text = [SHUtils displayText:_user.biography];
        bio.font = [UIFont systemFontOfSize:13];
        bio.textColor = [[SHTheme shared] textColor];
        bio.backgroundColor = [UIColor clearColor];
        bio.numberOfLines = 0;
        CGSize sz = [bio sizeThatFits:CGSizeMake(w - pad * 2, 200)];
        bio.frame = CGRectMake(pad, y, w - pad * 2, sz.height);
        [_headerView addSubview:bio];
        y += sz.height + 4;
    }
    if (_user.isPrivate) {
        UILabel *lock = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w - pad * 2, 16)];
        lock.text = [@"\U0001F512 " stringByAppendingString:L(@"This account is private")];
        lock.font = [UIFont systemFontOfSize:12];
        lock.textColor = [[SHTheme shared] secondaryTextColor];
        lock.backgroundColor = [UIColor clearColor];
        [_headerView addSubview:lock];
        y += 18;
    }
    y += 10;

    if (_isCurrentUser) {
        UIButton *saved = [UIButton buttonWithType:UIButtonTypeCustom];
        saved.frame = CGRectMake(pad, y, w - pad * 2, 32);
        saved.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [saved setTitle:L(@"Saved") forState:UIControlStateNormal];
        [saved setTitleColor:[[SHTheme shared] textColor] forState:UIControlStateNormal];
        [saved setBackgroundImage:[[SHTheme shared] buttonImageHighlighted:NO] forState:UIControlStateNormal];
        [saved setBackgroundImage:[[SHTheme shared] buttonImageHighlighted:YES] forState:UIControlStateHighlighted];
        [[SHTheme shared] embossButton:saved];
        [saved addTarget:self action:@selector(showSaved) forControlEvents:UIControlEventTouchUpInside];
        [_headerView addSubview:saved];
        y += 42;
    } else {
        UIButton *followBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        followBtn.frame = CGRectMake(pad, y, w - pad * 2, 32);
        followBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        BOOL following = _user.friendshipFollowing;
        [followBtn setTitle:following ? L(@"Following") : L(@"Follow") forState:UIControlStateNormal];
        [followBtn setTitleColor:following ? [[SHTheme shared] textColor] : [UIColor whiteColor] forState:UIControlStateNormal];
        // glossy iOS 6 buttons: grey when already following, the accent capsule otherwise
        if (following) {
            [followBtn setBackgroundImage:[[SHTheme shared] buttonImageHighlighted:NO] forState:UIControlStateNormal];
            [followBtn setBackgroundImage:[[SHTheme shared] buttonImageHighlighted:YES] forState:UIControlStateHighlighted];
        } else {
            [followBtn setBackgroundImage:[[SHTheme shared] accentButtonImageHighlighted:NO disabled:NO] forState:UIControlStateNormal];
            [followBtn setBackgroundImage:[[SHTheme shared] accentButtonImageHighlighted:YES disabled:NO] forState:UIControlStateHighlighted];
        }
        [[SHTheme shared] embossButton:followBtn];
        [followBtn addTarget:self action:@selector(followTapped:) forControlEvents:UIControlEventTouchUpInside];
        followBtn.tag = following ? 1 : 0;
        [_headerView addSubview:followBtn];
        y += 42;
    }

    _headerView.frame = CGRectMake(0, 0, w, y);
    _tableView.tableHeaderView = _headerView;
    [_tableView reloadData];
}

#pragma mark - Navigation from the header

- (void)settingsTapped
{
    SHSettingsViewController *vc = [[SHSettingsViewController alloc] init];
    [SHLinkRouter presentInNavigation:vc];
}

- (void)showFollowers
{
    if (!_pk.length) return;
    NSString *pk = _pk;
    SHUserListViewController *vc = [[SHUserListViewController alloc] initWithTitle:L(@"Followers")
        loader:^id(NSString *maxId, NSString *query, SHUserListResult result) {
            return [SHInstagram followersForPk:pk maxId:maxId query:query completion:result];
        } searchable:YES];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)showFollowing
{
    if (!_pk.length) return;
    NSString *pk = _pk;
    SHUserListViewController *vc = [[SHUserListViewController alloc] initWithTitle:L(@"Following")
        loader:^id(NSString *maxId, NSString *query, SHUserListResult result) {
            return [SHInstagram followingForPk:pk maxId:maxId query:query completion:result];
        } searchable:YES];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)showSaved
{
    SHGridViewController *vc = [[SHGridViewController alloc] initWithTitle:L(@"Saved") loader:^SHHTTPTask *(NSString *maxId, SHFeedCompletion completion) {
        return [SHInstagram savedFeedWithMaxId:maxId completion:completion];
    }];
    vc.emptyMessage = L(@"You haven't saved anything yet.");
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)followTapped:(UIButton *)btn
{
    [_task cancel];
    if (btn.tag == 1) {
        _task = [SHInstagram unfollowUser:_pk completion:^(BOOL ok, NSError *err) {
            if (ok) { self->_user.friendshipFollowing = NO; if (self->_user.followerCount > 0) self->_user.followerCount--; [self buildHeader]; }
        }];
    } else {
        _task = [SHInstagram followUser:_pk completion:^(BOOL ok, NSError *err) {
            if (ok) { self->_user.friendshipFollowing = YES; self->_user.followerCount++; [self buildHeader]; }
        }];
    }
}

- (void)loadPosts:(BOOL)more
{
    if (_loadingPosts || !_pk.length) return;
    _loadingPosts = YES;
    [_postsTask cancel];
    _postsTask = [SHInstagram userFeedForPk:_pk maxId:more ? _nextMaxId : nil completion:^(NSArray *posts, NSString *nextMaxId, NSError *error) {
        self->_loadingPosts = NO;
        if (error) return;
        if (!more) [self->_posts removeAllObjects];
        [self->_posts addObjectsFromArray:posts];
        self->_nextMaxId = nextMaxId;
        if (self->_posts.count == 0 && self->_user.isPrivate && !self->_user.friendshipFollowing && !self->_isCurrentUser) {
            self->_statusLabel.text = L(@"Follow this account to see their photos and videos.");
            self->_statusLabel.hidden = NO;
        }
        [self->_tableView reloadData];
    }];
}

#pragma mark - Grid

- (NSInteger)rows { return (NSInteger)((_posts.count + [SHGridRowCell columns] - 1) / [SHGridRowCell columns]); }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return [self rows]; }

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return [SHGridRowCell rowHeightForWidth:tableView.bounds.size.width];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    SHGridRowCell *cell = [tableView dequeueReusableCellWithIdentifier:SHProfileGridId];
    if (!cell) cell = [[SHGridRowCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:SHProfileGridId];
    cell.delegate = self;
    NSUInteger cols = [SHGridRowCell columns];
    NSUInteger start = (NSUInteger)indexPath.row * cols;
    NSMutableArray *row = [NSMutableArray array];
    for (NSUInteger i = start; i < start + cols && i < _posts.count; i++) [row addObject:_posts[i]];
    [cell configureWithPosts:row];
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ((NSUInteger)indexPath.row >= (NSUInteger)[self rows] - 2 && _nextMaxId.length && !_loadingPosts) [self loadPosts:YES];
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
