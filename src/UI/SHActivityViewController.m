#import "SHActivityViewController.h"
#import "SHProfileViewController.h"
#import "SHPostDetailViewController.h"
#import "SHFollowRequestsViewController.h"
#import "SHInstagram.h"
#import "SHModels.h"
#import "SHImageLoader.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHLinkRouter.h"
#import "SHCommon.h"

static NSString * const SHNewsCellId = @"NewsCell";

@interface SHNewsCell : UITableViewCell
@property (nonatomic, strong) SHImageView *avatar;
@property (nonatomic, strong) UILabel *textView2;
@property (nonatomic, strong) UIImageView *clockView;
@property (nonatomic, strong) UILabel *dateLabel;
@property (nonatomic, strong) SHImageView *thumb;
@end

@implementation SHNewsCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        SHTheme *theme = [SHTheme shared];
        _avatar = [[SHImageView alloc] initWithFrame:CGRectMake(12, 10, 44, 44)];
        [theme styleAvatar:_avatar radius:5];
        _avatar.maxPixels = 128;
        [self.contentView addSubview:_avatar];
        _textView2 = [[UILabel alloc] init];
        _textView2.numberOfLines = 2;
        _textView2.font = [UIFont systemFontOfSize:13];
        _textView2.textColor = [theme textColor];
        _textView2.highlightedTextColor = [UIColor whiteColor];
        _textView2.backgroundColor = [UIColor clearColor];
        [theme embossLabel:_textView2];
        [self.contentView addSubview:_textView2];
        _clockView = [[UIImageView alloc] initWithImage:[theme clockGlyph]];
        [self.contentView addSubview:_clockView];
        _dateLabel = [[UILabel alloc] init];
        _dateLabel.font = [UIFont boldSystemFontOfSize:11];
        _dateLabel.textColor = [theme secondaryTextColor];
        _dateLabel.highlightedTextColor = [UIColor whiteColor];
        _dateLabel.backgroundColor = [UIColor clearColor];
        [theme embossLabel:_dateLabel];
        [self.contentView addSubview:_dateLabel];
        _thumb = [[SHImageView alloc] initWithFrame:CGRectZero];
        _thumb.contentMode = UIViewContentModeScaleAspectFill;
        [theme styleAvatar:_thumb radius:3];
        _thumb.maxPixels = 128;
        [self.contentView addSubview:_thumb];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    BOOL hasThumb = _thumb.imageURL.length > 0;
    _thumb.frame = hasThumb ? CGRectMake(w - 56, 10, 44, 44) : CGRectZero;
    _thumb.hidden = !hasThumb;
    CGFloat right = hasThumb ? w - 66 : w - 12;
    CGFloat x = 66;
    _textView2.frame = CGRectMake(x, 7, right - x, 34);
    _clockView.frame = CGRectMake(x, 45, 12, 12);
    _dateLabel.frame = CGRectMake(x + 16, 43, right - x - 16, 16);
}
@end

@interface SHActivityViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray *stories;
@property (nonatomic, strong) SHHTTPTask *task;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic) BOOL fresh;
@end

@implementation SHActivityViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    SHTheme *theme = [SHTheme shared];
    self.title = L(@"Activity");
    self.view.backgroundColor = [theme linenColor];
    _stories = [NSMutableArray array];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 64;
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
    [_spinner startAnimating];

    [SHInstagram cachedNewsWithCompletion:^(NSArray *stories, NSError *error) {
        if (self->_fresh || !stories.count) return;
        [self->_stories setArray:stories];
        [self->_spinner stopAnimating];
        [self->_tableView reloadData];
    }];
    [self load];
}

- (void)dealloc { [_task cancel]; }

- (void)load
{
    [_task cancel];
    _task = [SHInstagram newsInboxWithCompletion:^(NSArray *stories, NSError *error) {
        [self->_spinner stopAnimating];
        if (error) {
            if (self->_stories.count == 0) { self->_statusLabel.text = error.localizedDescription; self->_statusLabel.hidden = NO; }
            return;
        }
        self->_fresh = YES;
        [self->_stories setArray:stories];
        self->_statusLabel.hidden = self->_stories.count > 0;
        if (self->_stories.count == 0) { self->_statusLabel.text = L(@"No recent activity."); self->_statusLabel.hidden = NO; }
        [self->_tableView reloadData];
    }];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    if (scrollView.contentOffset.y < -60) [self load];   // pull down to refresh
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_stories.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    SHNewsCell *cell = [tableView dequeueReusableCellWithIdentifier:SHNewsCellId];
    if (!cell) cell = [[SHNewsCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:SHNewsCellId];
    [[SHTheme shared] styleCell:cell];
    SHNewsStory *n = _stories[(NSUInteger)indexPath.row];
    [cell.avatar setImageURL:n.profilePicURL placeholder:[[SHTheme shared] avatarPlaceholderWithSize:44]];
    if (n.requestUsers.count) {
        // the pinned row: "Follow requests" in bold, who asked under it
        NSMutableArray *names = [NSMutableArray array];
        for (SHUser *u in n.requestUsers) if (u.username.length && names.count < 3) [names addObject:u.username];
        NSString *who = [names componentsJoinedByString:@", "];
        if (n.requestUsers.count > names.count) who = [NSString stringWithFormat:L(@"%@ and others"), who];
        NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@\n%@", n.text, who]
            attributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: [[SHTheme shared] secondaryTextColor] }];
        [a addAttributes:@{ NSFontAttributeName: [UIFont boldSystemFontOfSize:14], NSForegroundColorAttributeName: [[SHTheme shared] textColor] }
                   range:NSMakeRange(0, n.text.length)];
        cell.textView2.attributedText = a;
        cell.accessoryView = [[UIImageView alloc] initWithImage:[[SHTheme shared] disclosureChevronImage]];
    } else {
        cell.textView2.attributedText = nil;
        cell.textView2.text = [SHUtils displayText:n.text];
        cell.accessoryView = nil;
    }
    cell.dateLabel.text = n.timestamp ? [SHUtils formatRelativeDate:n.timestamp] : @"";
    cell.clockView.hidden = n.timestamp == nil;
    [cell.thumb setImageURL:n.mediaThumbURL.length ? n.mediaThumbURL : nil placeholder:nil];
    [cell setNeedsLayout];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SHNewsStory *n = _stories[(NSUInteger)indexPath.row];
    if (n.requestUsers.count) {
        SHFollowRequestsViewController *vc = [[SHFollowRequestsViewController alloc] init];
        __weak SHActivityViewController *weakSelf = self;
        vc.onChange = ^{ [weakSelf load]; };   // (the pinned row goes when nobody is left)
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    if (n.mediaPk.length) {
        [_task cancel];
        _task = [SHInstagram mediaInfo:n.mediaPk completion:^(SHPost *post, NSError *error) {
            if (error || !post) { if (n.username.length) [SHLinkRouter openProfile:n.username]; return; }
            SHPostDetailViewController *vc = [[SHPostDetailViewController alloc] initWithPost:post];
            [self.navigationController pushViewController:vc animated:YES];
        }];
    } else if (n.username.length || n.userPk.length) {
        SHProfileViewController *vc = [[SHProfileViewController alloc] initWithUsername:n.username pk:n.userPk];
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
