#import "SHChoiceViewController.h"
#import "SHTheme.h"
#import "SHCommon.h"

@implementation SHChoiceViewController

- (instancetype)init
{
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [[SHTheme shared] applyToTableView:self.tableView];
    [[SHTheme shared] applyToNavigationBar:self.navigationController.navigationBar];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.titles.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    BOOL subtitle = (NSUInteger)indexPath.row < self.subtitles.count && [[self.subtitles objectAtIndex:(NSUInteger)indexPath.row] length];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:subtitle ? UITableViewCellStyleSubtitle : UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = [self.titles objectAtIndex:(NSUInteger)indexPath.row];
    if (subtitle) {
        cell.detailTextLabel.text = [self.subtitles objectAtIndex:(NSUInteger)indexPath.row];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.numberOfLines = 2;
    }
    cell.accessoryType = indexPath.row == self.selectedIndex ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    [[SHTheme shared] styleGroupedCell:cell];
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    BOOL subtitle = (NSUInteger)indexPath.row < self.subtitles.count && [[self.subtitles objectAtIndex:(NSUInteger)indexPath.row] length];
    return subtitle ? 56 : 44;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    self.selectedIndex = indexPath.row;
    [tableView reloadData];
    if (self.completion) self.completion(indexPath.row);
    [self.navigationController popViewControllerAnimated:YES];
}

@end
