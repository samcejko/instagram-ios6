#import "SHMainTabController.h"
#import "SHFeedViewController.h"
#import "SHGridViewController.h"
#import "SHActivityViewController.h"
#import "SHInboxViewController.h"
#import "SHProfileViewController.h"
#import "SHTabIcons.h"
#import "SHInstagram.h"
#import "SHDirectMonitor.h"
#import "SHRealtime.h"
#import "SHPoller.h"
#import "SHSettings.h"
#import "SHTheme.h"
#import "SHCommon.h"

@implementation SHMainTabController {
    UIViewController *_inbox;
    SHPoller *_directPoller;   // the Direct tab's badge while the app is used elsewhere
}

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
    explore.secondaryTitle = L(@"Reels");
    explore.secondaryFullScreen = YES;   // one video per screen, swiped, like the app
    explore.secondaryLoader = ^SHHTTPTask *(NSString *maxId, SHFeedCompletion completion) {
        return [SHInstagram reelsWithMaxId:maxId completion:completion];
    };
    explore.secondaryCachedLoader = ^(SHFeedCompletion completion) { [SHInstagram cachedReelsWithCompletion:completion]; };

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

    // The number of unread chats on the Direct tab, as the app has it. Every inbox loaded counts; this asks for one
    // now and then only while the Direct tab itself is not on screen (it asks on its own then).
    _inbox = inbox;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(directUnreadChanged)
                                                 name:SHDirectUnreadDidChangeNotification object:nil];
    [self directUnreadChanged];
    __weak SHMainTabController *weakSelf = self;
    _directPoller = [[SHPoller alloc] initWithMinInterval:60 maxInterval:120 block:^(void (^done)(BOOL changed)) {
        SHMainTabController *s = weakSelf;
        SHDirectMonitor *monitor = [SHDirectMonitor shared];
        if (!s || [s inboxOnScreen] || monitor.secondsSinceInbox < 50) { done(NO); return; }
        NSUInteger before = monitor.unreadCount;
        [SHInstagram directInboxWithCursor:nil completion:^(NSArray *threads, NSString *cursor, NSError *error) {
            done(monitor.unreadCount != before);
        }];
    }];
    _directPoller.liveInterval = 600;   // (the live connection brings the messages; this only catches what it missed)
    [_directPoller startAfter:6];       // (after the feed's own first requests; its inbox also starts the connection)

    // Instagram's live connection, as the app keeps it: new messages, reads and typing at once (polling stays the
    // fallback). It waits for the first inbox (its seq_id) and lives only while the app is in front.
    if ([SHSettings isLoggedIn]) [[SHRealtime shared] start];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_directPoller stop];
    if (![SHSettings isLoggedIn]) [[SHRealtime shared] stop];   // (a new tab shell of the same account keeps it)
    [[SHDirectMonitor shared] reset];   // (logged out: the next account starts from nothing)
}

- (BOOL)inboxOnScreen
{
    UINavigationController *nav = (UINavigationController *)self.selectedViewController;
    return [nav isKindOfClass:[UINavigationController class]] && nav.topViewController == _inbox;
}

- (void)directUnreadChanged
{
    NSUInteger n = [SHDirectMonitor shared].unreadCount;
    _inbox.tabBarItem.badgeValue = n ? [NSString stringWithFormat:@"%lu", (unsigned long)n] : nil;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
