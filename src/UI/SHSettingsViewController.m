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

// The sections: the account, the look (dark or light), the sounds of messages, the network, the version.
enum { SHSectionAccount, SHSectionLook, SHSectionSounds, SHSectionNetwork, SHSectionVersion, SHSectionCount };

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return SHSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == SHSectionLook || section == SHSectionNetwork) return 2;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == SHSectionAccount) return L(@"Account");
    if (section == SHSectionLook) return L(@"Appearance");
    if (section == SHSectionSounds) return L(@"Sounds");
    if (section == SHSectionNetwork) return L(@"Network");
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

    if (indexPath.section == SHSectionAccount) {
        cell.textLabel.text = [SHSettings isLoggedIn]
            ? [NSString stringWithFormat:@"@%@", [SHSettings username]]
            : L(@"Not logged in");
        cell.detailTextLabel.text = [SHSettings isLoggedIn] ? L(@"Log Out") : nil;
        cell.detailTextLabel.textColor = [UIColor redColor];
    } else if (indexPath.section == SHSectionLook) {
        // the dark linen look or the light one, ticked as iOS 6 Settings ticks a choice
        BOOL darkRow = indexPath.row == 0;
        cell.textLabel.text = darkRow ? L(@"Dark") : L(@"Light");
        cell.detailTextLabel.text = nil;
        cell.accessoryType = darkRow == [SHTheme shared].isDark ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    } else if (indexPath.section == SHSectionSounds) {
        cell.textLabel.text = L(@"Message sounds");
        cell.detailTextLabel.text = nil;
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [SHSettings messageSounds];
        sw.tag = 2;
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == SHSectionNetwork) {
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
    if (indexPath.section == SHSectionAccount && [SHSettings isLoggedIn]) {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:L(@"Log Out") message:L(@"Are you sure?")
            delegate:self cancelButtonTitle:L(@"Cancel") otherButtonTitles:L(@"Log Out"), nil];
        [alert show];
    } else if (indexPath.section == SHSectionLook) {
        [self chooseDark:indexPath.row == 0];
    } else if (indexPath.section == SHSectionNetwork && indexPath.row == 1) {
        [SHSettings clearSearchHistory];
        [SHUtils alertWithTitle:L(@"Settings") message:L(@"Search history cleared.")];
    }
}

// Another look: every screen is drawn anew in it (the app's screens are built again, the account stays).
- (void)chooseDark:(BOOL)dark
{
    if ([SHTheme shared].isDark == dark) return;
    [[SHTheme shared] setDark:dark];
    [_tableView reloadData];
    [self dismissViewControllerAnimated:YES completion:^{
        if ([SHSettings isLoggedIn]) [[SHAppDelegate shared] showFeed];
        else [[SHAppDelegate shared] showLogin];
    }];
}

- (void)switchChanged:(UISwitch *)sw
{
    if (sw.tag == 1) [SHSettings setVerifyTLS:sw.on];
    if (sw.tag == 2) [SHSettings setMessageSounds:sw.on];
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
