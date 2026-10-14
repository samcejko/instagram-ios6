#import "SHMainTabController.h"
#import "SHFeedViewController.h"
#import "SHGridViewController.h"
#import "SHActivityViewController.h"
#import "SHInboxViewController.h"
#import "SHProfileViewController.h"
#import "SHTabIcons.h"
#import "SHInstagram.h"
#import "SHSettings.h"
#import "SHTheme.h"
#import "SHCommon.h"

@implementation SHMainTabController

- (UINavigationController *)wrap:(UIViewController *)vc title:(NSString *)title image:(UIImage *)image
{
    // The tab item must be set on the content controller: a navigation controller mirrors its top controller's
    // item, so setting it on the nav is overwritten once the root controller loads its own title (e.g. "Gramify").
    vc.tabBarItem = [[UITabBarItem alloc] initWithTitle:title image:image tag:0];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [[SHTheme shared] applyToNavigationBar:nav.navigationBar];
    return nav;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    SHFeedViewController *feed = [[SHFeedViewController alloc] init];

    SHGridViewController *explore = [[SHGridViewController alloc] initWithTitle:L(@"Explore") loader:^SHHTTPTask *(NSString *maxId, SHFeedCompletion completion) {
        return [SHInstagram exploreWithMaxId:maxId completion:completion];
    }];
    explore.emptyMessage = L(@"Nothing to explore right now.");

    SHActivityViewController *activity = [[SHActivityViewController alloc] init];
    SHInboxViewController *inbox = [[SHInboxViewController alloc] init];

    SHProfileViewController *me = [[SHProfileViewController alloc] initWithUsername:[SHSettings username] pk:[SHSettings userId]];
    me.isCurrentUser = YES;

    self.viewControllers = @[
        [self wrap:feed title:L(@"Home") image:[SHTabIcons home]],
        [self wrap:explore title:L(@"Explore") image:[SHTabIcons explore]],
        [self wrap:activity title:L(@"Activity") image:[SHTabIcons activity]],
        [self wrap:inbox title:L(@"Direct") image:[SHTabIcons direct]],
        [self wrap:me title:L(@"Profile") image:[SHTabIcons profile]],
    ];
    [[SHTheme shared] applyToTabBar:self.tabBar];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
