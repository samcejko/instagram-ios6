#import "SHSearchViewController.h"
#import "SHProfileViewController.h"
#import "SHInstagram.h"
#import "SHModels.h"
#import "SHSettings.h"
#import "SHImageLoader.h"
#import "SHLinkRouter.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHCommon.h"

@interface SHSearchViewController () <UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *results;
@property (nonatomic, strong) SHHTTPTask *task;
@end

@implementation SHSearchViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = L(@"Search");
    self.view.backgroundColor = [[SHTheme shared] backgroundColor];
    _results = @[];

    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    _searchBar.placeholder = L(@"Search users or #hashtags");
    _searchBar.delegate = self;
    _searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [[SHTheme shared] applyToSearchBar:_searchBar];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.tableHeaderView = _searchBar;
    [[SHTheme shared] applyToTableView:_tableView];
    [self.view addSubview:_tableView];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [_searchBar becomeFirstResponder];
}

- (void)dealloc { [_task cancel]; }

#pragma mark - UISearchBarDelegate

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    [searchBar resignFirstResponder];
    NSString *q = [searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!q.length) return;
    [SHSettings addSearch:q];
    [_task cancel];
    if ([q hasPrefix:@"#"]) {
        // "#…": tags (NSDictionary name / count); a tap opens the tag's posts
        _task = [SHInstagram searchHashtags:q completion:^(NSArray *tags, NSError *error) {
            if (error) { [SHUtils alertWithTitle:L(@"Search") message:error.localizedDescription]; return; }
            self->_results = tags ?: @[];
            [self->_tableView reloadData];
        }];
        return;
    }
    _task = [SHInstagram searchUsers:q completion:^(NSArray *users, NSError *error) {
        if (error) { [SHUtils alertWithTitle:L(@"Search") message:error.localizedDescription]; return; }
        self->_results = users ?: @[];
        [self->_tableView reloadData];
    }];
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_results.count; }

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath { return 56; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"U"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"U"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        [[SHTheme shared] styleAvatar:cell.imageView radius:5];
    }
    [[SHTheme shared] styleCell:cell];
    id result = _results[(NSUInteger)indexPath.row];
    if ([result isKindOfClass:[NSDictionary class]]) {
        // a tag: its name and how many posts it has, a "#" disc for the picture
        cell.textLabel.text = [@"#" stringByAppendingString:result[@"name"] ?: @""];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
        cell.detailTextLabel.text = [NSString stringWithFormat:L(@"%@ posts"), [SHUtils formatCount:[result[@"count"] integerValue]]];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
        cell.detailTextLabel.textColor = [[SHTheme shared] secondaryTextColor];
        cell.imageView.image = [self hashImage];
        return cell;
    }
    SHUser *u = result;
    cell.textLabel.text = u.username;
    cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
    cell.detailTextLabel.text = [SHUtils displayText:u.fullName];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
    cell.detailTextLabel.textColor = [[SHTheme shared] secondaryTextColor];
    cell.imageView.image = [[SHTheme shared] avatarPlaceholderWithSize:40];
    if (u.profilePicURL.length) {
        NSString *url = u.profilePicURL;
        // (a picture already in memory answers inside this call, before the row is in the table: it is this row's)
        __block BOOL settingUp = YES;
        [[SHImageLoader shared] loadImage:url maxPixels:80 completion:^(UIImage *image) {
            if (!image) return;
            if (!settingUp) {
                // (the row may show somebody else by now)
                NSIndexPath *now = [tableView indexPathForCell:cell];
                if (!now || (NSUInteger)now.row >= self->_results.count) return;
                id shown = self->_results[(NSUInteger)now.row];
                if (![shown isKindOfClass:[SHUser class]] || ![[shown profilePicURL] isEqualToString:url]) return;
            }
            CGFloat scale = image.size.width > 0 ? image.size.width * image.scale / 40.0f : 1;   // shown 40 points wide
            cell.imageView.image = [UIImage imageWithCGImage:image.CGImage scale:scale orientation:UIImageOrientationUp];
            [cell setNeedsLayout];
        }];
        settingUp = NO;
    }
    return cell;
}

// The picture of a tag row: a "#" pressed into a light disc.
- (UIImage *)hashImage
{
    static UIImage *image;
    if (image) return image;
    CGFloat s = 40;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(s, s), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor colorWithWhite:0.6f alpha:1] setFill];
    CGContextFillEllipseInRect(ctx, CGRectMake(0, 0, s, s));
    [[UIColor colorWithWhite:0.96f alpha:1] setFill];
    CGContextFillEllipseInRect(ctx, CGRectMake(1, 1, s - 2, s - 2));
    UIFont *font = [UIFont boldSystemFontOfSize:22];
    CGSize ts = [@"#" sizeWithFont:font];
    [[UIColor whiteColor] setFill];
    [@"#" drawAtPoint:CGPointMake(floorf((s - ts.width) / 2), floorf((s - ts.height) / 2) + 1) withFont:font];
    [[UIColor colorWithWhite:0.35f alpha:1] setFill];
    [@"#" drawAtPoint:CGPointMake(floorf((s - ts.width) / 2), floorf((s - ts.height) / 2)) withFont:font];
    image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    id result = _results[(NSUInteger)indexPath.row];
    if ([result isKindOfClass:[NSDictionary class]]) { [SHLinkRouter openHashtag:result[@"name"]]; return; }
    SHUser *u = result;
    SHProfileViewController *vc = [[SHProfileViewController alloc] initWithUsername:u.username pk:u.pk];
    [self.navigationController pushViewController:vc animated:YES];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
