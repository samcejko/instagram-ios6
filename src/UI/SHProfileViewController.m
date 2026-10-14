#import "SHProfileViewController.h"
#import "SHFeedCell.h"
#import "SHCommentsViewController.h"
#import "SHPostDetailViewController.h"
#import "SHInstagram.h"
#import "SHModels.h"
#import "SHImageLoader.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHLinkRouter.h"
#import "SHCommon.h"

@interface SHProfileViewController () <UITableViewDataSource, UITableViewDelegate, SHFeedCellDelegate>
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *pk;
@property (nonatomic, strong) SHUser *user;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) NSMutableArray *posts;
@property (nonatomic, copy) NSString *nextMaxId;
@property (nonatomic, strong) SHHTTPTask *task;
@property (nonatomic) BOOL loadingPosts;
@end

static NSString * const SHProfileCellId = @"ProfileFeedCell";

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
    self.title = _username.length ? [@"@" stringByAppendingString:_username] : L(@"Profile");
    self.view.backgroundColor = [[SHTheme shared] backgroundColor];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    [self.view addSubview:_tableView];

    [self loadProfile];
}

- (void)dealloc { [_task cancel]; }

- (void)loadProfile
{
    [_task cancel];
    void (^gotUser)(SHUser *, NSError *) = ^(SHUser *user, NSError *error) {
        if (error) { [SHUtils alertWithTitle:L(@"Profile") message:error.localizedDescription]; return; }
        self->_user = user;
        if (!self->_pk.length) self->_pk = user.pk;
        [self buildHeader];
        [self loadPosts:NO];
    };
    if (_pk.length) {
        _task = [SHInstagram userInfoByPk:_pk completion:gotUser];
    } else if (_username.length) {
        _task = [SHInstagram userInfoByUsername:_username completion:gotUser];
    }
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

    CGFloat statsX = pad + 72 + 20;
    CGFloat statsW = (w - statsX - pad) / 3;
    NSArray *labels = @[ [SHUtils formatCount:_user.mediaCount], [SHUtils formatCount:_user.followerCount], [SHUtils formatCount:_user.followingCount] ];
    NSArray *titles = @[ L(@"Posts"), L(@"Followers"), L(@"Following") ];
    for (NSUInteger i = 0; i < 3; i++) {
        UILabel *num = [[UILabel alloc] initWithFrame:CGRectMake(statsX + statsW * (CGFloat)i, pad + 8, statsW, 20)];
        num.text = labels[i];
        num.font = [UIFont boldSystemFontOfSize:16];
        num.textColor = [[SHTheme shared] textColor];
        num.textAlignment = NSTextAlignmentCenter;
        [_headerView addSubview:num];

        UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(statsX + statsW * (CGFloat)i, pad + 28, statsW, 16)];
        sub.text = titles[i];
        sub.font = [UIFont systemFontOfSize:11];
        sub.textColor = [[SHTheme shared] secondaryTextColor];
        sub.textAlignment = NSTextAlignmentCenter;
        [_headerView addSubview:sub];
    }

    CGFloat y = pad + 80;
    if (_user.fullName.length) {
        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w - pad * 2, 20)];
        name.text = _user.fullName;
        name.font = [UIFont boldSystemFontOfSize:14];
        name.textColor = [[SHTheme shared] textColor];
        [_headerView addSubview:name];
        y += 20;
    }
    if (_user.biography.length) {
        UILabel *bio = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w - pad * 2, 0)];
        bio.text = [SHUtils displayText:_user.biography];
        bio.font = [UIFont systemFontOfSize:13];
        bio.textColor = [[SHTheme shared] textColor];
        bio.numberOfLines = 0;
        CGSize sz = [bio sizeThatFits:CGSizeMake(w - pad * 2, 100)];
        bio.frame = CGRectMake(pad, y, w - pad * 2, sz.height);
        [_headerView addSubview:bio];
        y += sz.height + 4;
    }
    y += 10;

    UIButton *followBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    followBtn.frame = CGRectMake(pad, y, w - pad * 2, 32);
    followBtn.layer.cornerRadius = 4;
    followBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    BOOL following = _user.friendshipFollowing;
    [followBtn setTitle:following ? L(@"Following") : L(@"Follow") forState:UIControlStateNormal];
    [followBtn setTitleColor:following ? [[SHTheme shared] textColor] : [UIColor whiteColor] forState:UIControlStateNormal];
    followBtn.backgroundColor = following ? [[SHTheme shared] separatorColor] : [SHUtils colorFromHex:@"#0095F6"];
    [followBtn addTarget:self action:@selector(followTapped:) forControlEvents:UIControlEventTouchUpInside];
    followBtn.tag = following ? 1 : 0;
    [_headerView addSubview:followBtn];
    y += 42;

    _headerView.frame = CGRectMake(0, 0, w, y);
    _tableView.tableHeaderView = _headerView;
    [_tableView reloadData];
}

- (void)followTapped:(UIButton *)btn
{
    [_task cancel];
    if (btn.tag == 1) {
        _task = [SHInstagram unfollowUser:_pk completion:^(BOOL ok, NSError *err) {
            if (ok) { self->_user.friendshipFollowing = NO; [self buildHeader]; }
        }];
    } else {
        _task = [SHInstagram followUser:_pk completion:^(BOOL ok, NSError *err) {
            if (ok) { self->_user.friendshipFollowing = YES; [self buildHeader]; }
        }];
    }
}

- (void)loadPosts:(BOOL)more
{
    if (_loadingPosts || !_pk.length) return;
    _loadingPosts = YES;
    [SHInstagram userFeedForPk:_pk maxId:more ? _nextMaxId : nil completion:^(NSArray *posts, NSString *nextMaxId, NSError *error) {
        self->_loadingPosts = NO;
        if (error) return;
        if (!more) [self->_posts removeAllObjects];
        [self->_posts addObjectsFromArray:posts];
        self->_nextMaxId = nextMaxId;
        [self->_tableView reloadData];
    }];
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_posts.count; }

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return [SHFeedCell heightForPost:_posts[(NSUInteger)indexPath.row] width:tableView.bounds.size.width];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    SHFeedCell *cell = [tableView dequeueReusableCellWithIdentifier:SHProfileCellId];
    if (!cell) cell = [[SHFeedCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:SHProfileCellId];
    cell.delegate = self;
    [cell configureWithPost:_posts[(NSUInteger)indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ((NSUInteger)indexPath.row >= _posts.count - 3 && _nextMaxId.length && !_loadingPosts) [self loadPosts:YES];
}

#pragma mark - SHFeedCellDelegate

- (void)feedCell:(SHFeedCell *)cell didTapUser:(NSString *)pk username:(NSString *)username
{
    if ([pk isEqualToString:_pk]) return;
    SHProfileViewController *vc = [[SHProfileViewController alloc] initWithUsername:username pk:pk];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)feedCell:(SHFeedCell *)cell didTapLikeOnPost:(SHPost *)post
{
    BOOL willLike = !post.hasLiked;
    if (willLike) {
        [SHInstagram likePost:post.pk completion:^(BOOL ok, NSError *err) {
            if (ok) { post.hasLiked = YES; post.likeCount++; [cell configureWithPost:post]; }
        }];
    } else {
        [SHInstagram unlikePost:post.pk completion:^(BOOL ok, NSError *err) {
            if (ok) { post.hasLiked = NO; post.likeCount = MAX(0, post.likeCount - 1); [cell configureWithPost:post]; }
        }];
    }
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

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
