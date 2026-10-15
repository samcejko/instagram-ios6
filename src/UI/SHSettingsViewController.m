#import "SHSettingsViewController.h"
#import "SHInstagram.h"
#import "SHSettings.h"
#import "SHAppDelegate.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHCommon.h"

@interface SHSettingsViewController () <UITableViewDataSource, UITableViewDelegate, UIAlertViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@end

@implementation SHSettingsViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = L(@"Settings");
    self.view.backgroundColor = [[SHTheme shared] backgroundColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:L(@"Done")
        style:UIBarButtonItemStyleDone target:self action:@selector(dismissSelf)];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.backgroundColor = [[SHTheme shared] backgroundColor];
    [[SHTheme shared] applyToTableView:_tableView];
    [self.view addSubview:_tableView];
}

- (void)dismissSelf { [self dismissViewControllerAnimated:YES completion:nil]; }

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 1;
    if (section == 1) return 2;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return L(@"Account");
    if (section == 1) return L(@"Network");
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"S"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"S"];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    [[SHTheme shared] styleGroupedCell:cell];
    cell.textLabel.textColor = [[SHTheme shared] textColor];
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;

    if (indexPath.section == 0) {
        cell.textLabel.text = [SHSettings isLoggedIn]
            ? [NSString stringWithFormat:@"@%@", [SHSettings username]]
            : L(@"Not logged in");
        cell.detailTextLabel.text = [SHSettings isLoggedIn] ? L(@"Log Out") : nil;
        cell.detailTextLabel.textColor = [UIColor redColor];
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = L(@"Verify TLS certificates");
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [SHSettings verifyTLS];
            sw.tag = 1;
            [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.textLabel.text = L(@"Clear search history");
            cell.detailTextLabel.text = nil;
        }
    } else {
        cell.textLabel.text = [NSString stringWithFormat:@"Gramify %@", [SHUtils appVersion]];
        cell.textLabel.textColor = [[SHTheme shared] secondaryTextColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.detailTextLabel.text = nil;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0 && [SHSettings isLoggedIn]) {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:L(@"Log Out") message:L(@"Are you sure?")
            delegate:self cancelButtonTitle:L(@"Cancel") otherButtonTitles:L(@"Log Out"), nil];
        [alert show];
    } else if (indexPath.section == 1 && indexPath.row == 1) {
        [SHSettings clearSearchHistory];
        [SHUtils alertWithTitle:L(@"Settings") message:L(@"Search history cleared.")];
    }
}

- (void)switchChanged:(UISwitch *)sw
{
    if (sw.tag == 1) [SHSettings setVerifyTLS:sw.on];
}

#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex != alertView.cancelButtonIndex) {
        [SHInstagram logoutWithCompletion:^(BOOL ok, NSError *err) {
            [self dismissViewControllerAnimated:YES completion:^{
                [[SHAppDelegate shared] showLogin];
            }];
        }];
    }
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
