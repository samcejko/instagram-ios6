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
@property (nonatomic, strong) SHHTTPTask *friendshipTask;
@property (nonatomic) BOOL loadingPosts;
@property (nonatomic) BOOL changingFollow;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

static NSString * const SHProfileGridId = @"ProfileGridRow";
static const CGFloat SHProfileAvatar = 84;

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
    SHTheme *theme = [SHTheme shared];
    // Put the username in the nav bar, not self.title, so the Profile tab keeps its "Profil" item.
    self.navigationItem.title = _username.length ? _username : L(@"Profile");
    self.view.backgroundColor = [theme linenColor];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    [theme applyToTableView:_tableView];
    [self.view addSubview:_tableView];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 260, self.view.bounds.size.width - 40, 60)];
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _statusLabel.numberOfLines = 0;
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.font = [UIFont boldSystemFontOfSize:15];
    _statusLabel.textColor = [theme secondaryTextColor];
    _statusLabel.backgroundColor = [UIColor clearColor];
    [theme embossLabel:_statusLabel];
    _statusLabel.hidden = YES;
    [self.view addSubview:_statusLabel];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:[theme spinnerStyle]];
    _spinner.center = CGPointMake(self.view.bounds.size.width / 2, 90);
    _spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    _spinner.hidesWhenStopped = YES;
    [self.view addSubview:_spinner];

    if (_isCurrentUser) {
        UIBarButtonItem *gear = [[UIBarButtonItem alloc] initWithImage:[theme gearBarIcon] style:UIBarButtonItemStyleBordered
                                                                target:self action:@selector(settingsTapped)];
        gear.accessibilityLabel = L(@"Settings");
        self.navigationItem.rightBarButtonItem = gear;
    }

    [self loadProfile];
}

- (void)dealloc { [_task cancel]; [_postsTask cancel]; [_friendshipTask cancel]; }

- (void)loadProfile
{
    [_task cancel];
    if (!_user) [_spinner startAnimating];
    void (^gotUser)(SHUser *, NSError *) = ^(SHUser *user, NSError *error) {
        [self->_spinner stopAnimating];
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
        [self loadFriendship];
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

// Where this account stands with the viewer (following, asked to follow): the profile itself does not always say.
- (void)loadFriendship
{
    if (_isCurrentUser || !_pk.length || [_pk isEqualToString:[SHSettings userId]]) return;
    [_friendshipTask cancel];
    _friendshipTask = [SHInstagram friendshipWithUser:_pk completion:^(BOOL following, BOOL requested, NSError *error) {
        if (error || !self->_user) return;
        if (following == self->_user.friendshipFollowing && requested == self->_user.friendshipRequested) return;
        self->_user.friendshipFollowing = following;
        self->_user.friendshipRequested = requested;
        [self buildHeader];
    }];
}

// One of the three counts in the glossy box: the number above, what it counts under it.
- (UIButton *)statButton:(NSString *)number title:(NSString *)title frame:(CGRect)frame action:(SEL)action
{
    SHTheme *theme = [SHTheme shared];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = frame;
    if (action) {
        [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
        [b setBackgroundImage:[SHUtils imageWithColor:[UIColor colorWithWhite:theme.isDark ? 1 : 0 alpha:0.08] size:CGSizeMake(2, 2)]
                     forState:UIControlStateHighlighted];
    }
    UILabel *num = [[UILabel alloc] initWithFrame:CGRectMake(0, 7, frame.size.width, 22)];
    num.text = number;
    num.font = [UIFont boldSystemFontOfSize:18];
    num.textColor = [theme textColor];
    num.textAlignment = NSTextAlignmentCenter;
    num.backgroundColor = [UIColor clearColor];
    [theme embossLabel:num];
    [b addSubview:num];
    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(0, 30, frame.size.width, 16)];
    sub.text = title;
    sub.font = [UIFont boldSystemFontOfSize:11];
    sub.textColor = theme.isDark ? [UIColor colorWithWhite:0.78 alpha:1] : [theme secondaryTextColor];   // (readable on the gloss)
    sub.textAlignment = NSTextAlignmentCenter;
    sub.backgroundColor = [UIColor clearColor];
    [theme embossLabel:sub];
    [b addSubview:sub];
    return b;
}

// An etched vertical line between two counts of the box.
- (UIView *)etchedDividerAtX:(CGFloat)x height:(CGFloat)h
{
    BOOL dark = [[SHTheme shared] isDark];
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(x, 6, 2, h - 12)];
    UIView *a = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, h - 12)];
    a.backgroundColor = [UIColor colorWithWhite:0 alpha:dark ? 0.7 : 0.18];
    UIView *b = [[UIView alloc] initWithFrame:CGRectMake(1, 0, 1, h - 12)];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:dark ? 0.08 : 0.85];
    [v addSubview:a];
    [v addSubview:b];
    return v;
}

- (void)buildHeader
{
    SHTheme *theme = [SHTheme shared];
    CGFloat w = self.view.bounds.size.width;
    CGFloat pad = 14;
    _headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 200)];
    _headerView.backgroundColor = [UIColor clearColor];

    // the picture in a white frame with a shadow under it, the way the old app showed it
    UIView *frameView = [[UIView alloc] initWithFrame:CGRectMake(pad, pad, SHProfileAvatar, SHProfileAvatar)];
    frameView.backgroundColor = [UIColor whiteColor];
    frameView.layer.cornerRadius = 8;
    frameView.layer.shadowColor = [UIColor blackColor].CGColor;
    frameView.layer.shadowOpacity = 0.6;
    frameView.layer.shadowRadius = 2;
    frameView.layer.shadowOffset = CGSizeMake(0, 1);
    frameView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:frameView.bounds cornerRadius:8].CGPath;
    SHImageView *avatar = [[SHImageView alloc] initWithFrame:CGRectInset(frameView.bounds, 3, 3)];
    [theme styleAvatar:avatar radius:6];
    avatar.maxPixels = 200;
    [avatar setImageURL:_user.profilePicURL placeholder:[theme avatarPlaceholderWithSize:SHProfileAvatar - 6]];
    [frameView addSubview:avatar];
    [_headerView addSubview:frameView];

    // the counts in one glossy box, split by etched lines
    CGFloat boxX = pad + SHProfileAvatar + 12, boxW = w - boxX - pad, boxH = 52;
    UIImageView *box = [[UIImageView alloc] initWithImage:[theme statBoxImage]];
    box.frame = CGRectMake(boxX, pad + 2, boxW, boxH);
    box.userInteractionEnabled = YES;
    CGFloat cellW = floorf(boxW / 3);
    [box addSubview:[self statButton:[SHUtils formatCount:_user.mediaCount] title:L(@"Posts") frame:CGRectMake(0, 0, cellW, boxH) action:nil]];
    [box addSubview:[self statButton:[SHUtils formatCount:_user.followerCount] title:L(@"Followers")
                               frame:CGRectMake(cellW, 0, cellW, boxH) action:@selector(showFollowers)]];
    [box addSubview:[self statButton:[SHUtils formatCount:_user.followingCount] title:L(@"Following")
                               frame:CGRectMake(cellW * 2, 0, boxW - cellW * 2, boxH) action:@selector(showFollowing)]];
    [box addSubview:[self etchedDividerAtX:cellW - 1 height:boxH]];
    [box addSubview:[self etchedDividerAtX:cellW * 2 - 1 height:boxH]];
    [_headerView addSubview:box];

    // under the box: follow (or Saved for oneself)
    CGFloat buttonY = pad + 2 + boxH + 8;
    UIButton *action = [UIButton buttonWithType:UIButtonTypeCustom];
    action.frame = CGRectMake(boxX, buttonY, boxW, 30);
    action.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    if (_isCurrentUser) {
        [action setTitle:L(@"Saved") forState:UIControlStateNormal];
        [action setTitleColor:[theme textColor] forState:UIControlStateNormal];
        [action setBackgroundImage:[theme buttonImageHighlighted:NO] forState:UIControlStateNormal];
        [action setBackgroundImage:[theme buttonImageHighlighted:YES] forState:UIControlStateHighlighted];
        [action addTarget:self action:@selector(showSaved) forControlEvents:UIControlEventTouchUpInside];
    } else {
        BOOL following = _user.friendshipFollowing || _user.friendshipRequested;   // a pending request reads "Requested"
        [action setTitle:_user.friendshipFollowing ? L(@"Following") : _user.friendshipRequested ? L(@"Requested") : L(@"Follow")
                forState:UIControlStateNormal];
        [action setTitleColor:following ? [theme textColor] : [UIColor whiteColor] forState:UIControlStateNormal];
        // glossy iOS 6 buttons: grey when already following (or asked to), the blue one otherwise
        if (following) {
            [action setBackgroundImage:[theme buttonImageHighlighted:NO] forState:UIControlStateNormal];
            [action setBackgroundImage:[theme buttonImageHighlighted:YES] forState:UIControlStateHighlighted];
        } else {
            [action setBackgroundImage:[theme accentButtonImageHighlighted:NO disabled:NO] forState:UIControlStateNormal];
            [action setBackgroundImage:[theme accentButtonImageHighlighted:YES disabled:NO] forState:UIControlStateHighlighted];
        }
        action.tag = following ? 1 : 0;
        action.enabled = !_changingFollow;
        [action addTarget:self action:@selector(followTapped:) forControlEvents:UIControlEventTouchUpInside];
    }
    [theme embossButton:action];
    [_headerView addSubview:action];

    CGFloat y = MAX(pad + SHProfileAvatar, buttonY + 30) + 12;
    NSString *displayName = [SHUtils displayText:_user.fullName.length ? _user.fullName : _user.username];
    if (displayName.length) {
        UILabel *name = [[UILabel alloc] init];
        name.text = displayName;
        name.font = [UIFont boldSystemFontOfSize:15];
        name.textColor = [theme textColor];
        name.backgroundColor = [UIColor clearColor];
        [theme embossLabel:name];
        CGFloat nameW = MIN(w - pad * 2 - 22, [displayName sizeWithFont:name.font].width);
        name.frame = CGRectMake(pad, y, nameW, 20);
        [_headerView addSubview:name];
        if (_user.isVerified) {
            UIImageView *badge = [[UIImageView alloc] initWithImage:[theme verifiedBadgeWithSize:15]];
            badge.frame = CGRectMake(pad + nameW + 5, y + 3, 15, 15);
            [_headerView addSubview:badge];
        }
        y += 22;
    }
    if (_user.biography.length) {
        UILabel *bio = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w - pad * 2, 0)];
        bio.text = [SHUtils displayText:_user.biography];
        bio.font = [UIFont systemFontOfSize:13];
        bio.textColor = [theme textColor];
        bio.backgroundColor = [UIColor clearColor];
        bio.numberOfLines = 0;
        [theme embossLabel:bio];
        CGSize sz = [bio sizeThatFits:CGSizeMake(w - pad * 2, 200)];
        bio.frame = CGRectMake(pad, y, w - pad * 2, sz.height);
        [_headerView addSubview:bio];
        y += sz.height + 4;
    }
    if (_user.isPrivate) {
        UIImageView *lock = [[UIImageView alloc] initWithImage:[theme lockGlyph]];
        lock.frame = CGRectMake(pad, y + 1, 12, 14);
        [_headerView addSubview:lock];
        UILabel *text = [[UILabel alloc] initWithFrame:CGRectMake(pad + 17, y, w - pad * 2 - 17, 16)];
        text.text = L(@"This account is private");
        text.font = [UIFont boldSystemFontOfSize:12];
        text.textColor = [theme secondaryTextColor];
        text.backgroundColor = [UIColor clearColor];
        [theme embossLabel:text];
        [_headerView addSubview:text];
        y += 20;
    }
    y += 10;

    // an etched groove between the header and the grid
    UIView *groove = [self etchedDividerAtX:0 height:0];
    groove.frame = CGRectMake(0, y - 2, w, 2);
    for (UIView *line in groove.subviews) line.frame = CGRectMake(0, line == groove.subviews.firstObject ? 0 : 1, w, 1);
    groove.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_headerView addSubview:groove];

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

// Follow, unfollow, or take back a request: what Instagram reports back is what the button shows then.
- (void)followTapped:(UIButton *)btn
{
    if (_changingFollow || !_pk.length) return;
    _changingFollow = YES;
    btn.enabled = NO;
    BOOL wasFollowing = _user.friendshipFollowing;
    [SHInstagram setFollowing:(btn.tag == 0) user:_pk completion:^(BOOL following, BOOL requested, NSError *error) {
        self->_changingFollow = NO;
        if (error) {
            [SHUtils alertWithTitle:L(@"Profile") message:error.localizedDescription];
            [self buildHeader];
            return;
        }
        if (following && !wasFollowing) self->_user.followerCount++;
        if (!following && wasFollowing && self->_user.followerCount > 0) self->_user.followerCount--;
        self->_user.friendshipFollowing = following;
        self->_user.friendshipRequested = requested;
        [self buildHeader];
        if (following && !wasFollowing && self->_posts.count == 0) [self loadPosts:NO];
    }];
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
        BOOL locked = self->_posts.count == 0 && self->_user.isPrivate && !self->_user.friendshipFollowing && !self->_isCurrentUser;
        if (locked) {
            self->_statusLabel.text = L(@"Follow this account to see their photos and videos.");
            CGRect f = self->_statusLabel.frame;
            f.origin.y = self->_headerView.frame.size.height + 30;
            self->_statusLabel.frame = f;
        }
        self->_statusLabel.hidden = !locked;
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
    if (indexPath.row + 2 >= [self rows] && _nextMaxId.length && !_loadingPosts) [self loadPosts:YES];
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
