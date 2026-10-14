#import "SHAppDelegate.h"
#import "SHLoginViewController.h"
#import "SHFeedViewController.h"
#import "SHLinkRouter.h"
#import "SHInstagram.h"
#import "SHMediaProxy.h"
#import "SHTLSSocket.h"
#import "SHImageLoader.h"
#import "SHSettings.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHModern.h"
#import "SHCommon.h"
#include <signal.h>

@implementation SHAppDelegate

+ (instancetype)shared { return (SHAppDelegate *)[UIApplication sharedApplication].delegate; }

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    signal(SIGPIPE, SIG_IGN);
    [SHSettings registerDefaults];
    SHLog(@"Gramify %@ starting on %@ (iOS %@)", [SHUtils appVersion], [SHUtils deviceModel],
          [UIDevice currentDevice].systemVersion);
    SHModernSetUp([[SHTheme shared] barStyle]);
    [SHTLSSocket warmUp];
    [[SHImageLoader shared] pruneDisk];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.backgroundColor = [UIColor blackColor];

    if ([SHSettings isLoggedIn]) {
        [self showFeed];
    } else {
        [self showLogin];
    }

    [self.window makeKeyAndVisible];
    [application setStatusBarStyle:UIStatusBarStyleBlackOpaque animated:NO];
    return YES;
}

- (void)showLogin
{
    SHLoginViewController *login = [[SHLoginViewController alloc] init];
    self.window.rootViewController = login;
}

- (void)showFeed
{
    SHFeedViewController *feed = [[SHFeedViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:feed];
    [[SHTheme shared] applyToNavigationBar:nav.navigationBar];
    self.window.rootViewController = nav;
}

- (UIViewController *)topController
{
    UIViewController *top = self.window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:[UINavigationController class]]) top = [(UINavigationController *)top topViewController];
    return top;
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation
{
    NSString *s = url.absoluteString ?: @"";
    NSString *lower = [s lowercaseString];
    if ([lower hasPrefix:@"http://"] || [lower hasPrefix:@"https://"]) return [SHLinkRouter openLink:s];
    NSString *scheme = [lower hasPrefix:@"shutter:"] ? @"shutter:" : nil;
    if (!scheme) return NO;
    NSString *target = [s substringFromIndex:scheme.length];
    while ([target hasPrefix:@"/"]) target = [target substringFromIndex:1];
    NSString *query = nil;
    NSRange q = [target rangeOfString:@"?"];
    if (q.location != NSNotFound) { query = [target substringFromIndex:q.location + 1]; target = [target substringToIndex:q.location]; }
    NSDictionary *params = query.length ? [SHUtils parseQuery:query] : @{};

    if ([target hasPrefix:@"user/"]) { [SHLinkRouter openProfile:[target substringFromIndex:@"user/".length]]; return YES; }
    if ([target hasPrefix:@"post/"]) { [SHLinkRouter openPost:[target substringFromIndex:@"post/".length]]; return YES; }
    if ([target isEqualToString:@"open"] && [params[@"url"] length]) {
        if (![SHLinkRouter openLink:params[@"url"]]) [SHUtils alertWithTitle:L(@"Open a link") message:L(@"That does not look like an Instagram link.")];
        return YES;
    }

    BOOL debug = [[NSFileManager defaultManager] fileExistsAtPath:[[SHUtils documentsPath] stringByAppendingPathComponent:@"debug"]];
    if (!debug) return YES;

    if ([target isEqualToString:@"stats"]) {
        SHLog(@"Top: %@, proxy %@", NSStringFromClass([[self topController] class]), [[SHMediaProxy shared] statsDescription]);
        return YES;
    }
    if ([target isEqualToString:@"lang"]) {
        NSString *set = params[@"set"] ?: @"system";
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if ([set isEqualToString:@"system"]) [d removeObjectForKey:@"AppleLanguages"];
        else [d setObject:@[ set ] forKey:@"AppleLanguages"];
        [d synchronize];
        SHLog(@"Language %@ from the next launch: quitting", set);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
        return YES;
    }
    return YES;
}

- (void)applicationWillEnterForeground:(UIApplication *)application { [[SHMediaProxy shared] ensureRunning]; }
- (void)applicationDidEnterBackground:(UIApplication *)application { [SHSettings save]; }

@end
