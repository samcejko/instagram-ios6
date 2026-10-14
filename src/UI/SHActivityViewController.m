#import "SHActivityViewController.h"
#import "SHProfileViewController.h"
#import "SHPostDetailViewController.h"
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
@property (nonatomic, strong) UILabel *dateLabel;
@property (nonatomic, strong) SHImageView *thumb;
@end

@implementation SHNewsCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        _avatar = [[SHImageView alloc] initWithFrame:CGRectMake(12, 10, 40, 40)];
        _avatar.layer.cornerRadius = 20;
        _avatar.clipsToBounds = YES;
        _avatar.backgroundColor = [[SHTheme shared] separatorColor];
        [self.contentView addSubview:_avatar];
        _textView2 = [[UILabel alloc] init];
        _textView2.numberOfLines = 2;
        _textView2.font = [UIFont systemFontOfSize:13];
        _textView2.textColor = [[SHTheme shared] textColor];
        _textView2.backgroundColor = [UIColor clearColor];
        [self.contentView addSubview:_textView2];
        _dateLabel = [[UILabel alloc] init];
        _dateLabel.font = [UIFont systemFontOfSize:11];
        _dateLabel.textColor = [[SHTheme shared] secondaryTextColor];
        _dateLabel.backgroundColor = [UIColor clearColor];
        [self.contentView addSubview:_dateLabel];
        _thumb = [[SHImageView alloc] initWithFrame:CGRectZero];
        _thumb.contentMode = UIViewContentModeScaleAspectFill;
        _thumb.clipsToBounds = YES;
        _thumb.backgroundColor = [[SHTheme shared] separatorColor];
        [self.contentView addSubview:_thumb];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    BOOL hasThumb = _thumb.imageURL.length > 0;
    _thumb.frame = hasThumb ? CGRectMake(w - 52, 10, 40, 40) : CGRectZero;
    _thumb.hidden = !hasThumb;
    CGFloat right = hasThumb ? w - 62 : w - 12;
    CGFloat x = 62;
    _textView2.frame = CGRectMake(x, 8, right - x, 34);
    _dateLabel.frame = CGRectMake(x, 44, right - x, 14);
}
@end

@interface SHActivityViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray *stories;
@property (nonatomic, strong) SHHTTPTask *task;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation SHActivityViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = L(@"Activity");
    self.view.backgroundColor = [[SHTheme shared] backgroundColor];
    _stories = [NSMutableArray array];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 60;
    [self.view addSubview:_tableView];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 30, 0)];
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _statusLabel.numberOfLines = 0;
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.font = [UIFont systemFontOfSize:14];
    _statusLabel.textColor = [[SHTheme shared] secondaryTextColor];
    _statusLabel.hidden = YES;
    [self.view addSubview:_statusLabel];

    [self load];
}

- (void)dealloc { [_task cancel]; }

- (void)load
{
    [_task cancel];
    _task = [SHInstagram newsInboxWithCompletion:^(NSArray *stories, NSError *error) {
        if (error) {
            if (self->_stories.count == 0) { self->_statusLabel.text = error.localizedDescription; self->_statusLabel.hidden = NO; }
            return;
        }
        [self->_stories setArray:stories];
        self->_statusLabel.hidden = self->_stories.count > 0;
        if (self->_stories.count == 0) { self->_statusLabel.text = L(@"No recent activity."); self->_statusLabel.hidden = NO; }
        [self->_tableView reloadData];
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_stories.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    SHNewsCell *cell = [tableView dequeueReusableCellWithIdentifier:SHNewsCellId];
    if (!cell) cell = [[SHNewsCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:SHNewsCellId];
    SHNewsStory *n = _stories[(NSUInteger)indexPath.row];
    [cell.avatar setImageURL:n.profilePicURL placeholder:nil];
    cell.textView2.text = [SHUtils displayText:n.text];
    cell.dateLabel.text = n.timestamp ? [SHUtils formatRelativeDate:n.timestamp] : @"";
    [cell.thumb setImageURL:n.mediaThumbURL.length ? n.mediaThumbURL : nil placeholder:nil];
    [[SHTheme shared] styleCell:cell];
    [cell setNeedsLayout];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SHNewsStory *n = _stories[(NSUInteger)indexPath.row];
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
