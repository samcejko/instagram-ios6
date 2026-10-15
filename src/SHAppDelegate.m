#import "SHAppDelegate.h"
#import "SHLoginViewController.h"
#import "SHFeedViewController.h"
#import "SHMainTabController.h"
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
#import <QuartzCore/QuartzCore.h>
#include <objc/runtime.h>
#include <signal.h>

@implementation SHAppDelegate

+ (instancetype)shared { return (SHAppDelegate *)[UIApplication sharedApplication].delegate; }

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    signal(SIGPIPE, SIG_IGN);
    [SHSettings registerDefaults];
    // iOS 6 UILabels default to an opaque (white) background, which shows as boxes behind text on the dark theme.
    // Make the default transparent app-wide; labels that need a fill (chat bubbles) set their colour explicitly.
    [[UILabel appearance] setBackgroundColor:[UIColor clearColor]];
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
    self.window.rootViewController = [[SHMainTabController alloc] init];
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
    if ([target isEqualToString:@"snapshot"] || [target isEqualToString:@"screen"]) {
        [self writeSnapshot];
        return YES;
    }
    if ([target isEqualToString:@"probe"]) {
        [SHInstagram probeConnectivityWithCompletion:^(BOOL ok, NSString *detail, NSError *error) {
            SHLog(@"PROBE %@ — %@%@", ok ? @"OK" : @"FAIL", detail ?: @"", error ? [@" error: " stringByAppendingString:error.localizedDescription] : @"");
        }];
        return YES;
    }
    if ([target isEqualToString:@"enctest"]) {
        [SHInstagram encryptionSelfTestWithCompletion:^(BOOL ok, NSString *detail) {
            SHLog(@"ENCTEST %@ — %@", ok ? @"PASS" : @"FAIL", detail ?: @"");
        }];
        return YES;
    }
    if ([target isEqualToString:@"loginprobe"]) {
        [SHInstagram loginFormatProbeWithCompletion:^(NSString *detail) {
            SHLog(@"LOGINPROBE — %@", detail ?: @"");
        }];
        return YES;
    }
    if ([target isEqualToString:@"showtabs"]) {
        [self showFeed];   // the main tab shell, even without a session, to inspect the layout
        return YES;
    }
    if ([target isEqualToString:@"tab"]) {
        NSInteger idx = [params[@"i"] integerValue];
        UIViewController *root = self.window.rootViewController;
        if ([root isKindOfClass:[UITabBarController class]] && idx >= 0 && idx < (NSInteger)[(UITabBarController *)root viewControllers].count)
            [(UITabBarController *)root setSelectedIndex:idx];
        return YES;
    }
    if ([target isEqualToString:@"press"]) {
        CGPoint pt = CGPointMake([params[@"x"] floatValue], [params[@"y"] floatValue]);
        [self pressAtPoint:pt];
        return YES;
    }
    if ([target isEqualToString:@"back"]) {   // the back button of a navigation bar is not a control: pop directly
        UIViewController *top = [self topController];
        [top.navigationController popViewControllerAnimated:YES];
        return YES;
    }
    if ([target isEqualToString:@"close"]) {  // dismiss whatever is presented modally
        UIViewController *top = self.window.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        [top.presentingViewController dismissViewControllerAnimated:YES completion:nil];
        return YES;
    }
    if ([target isEqualToString:@"scroll"]) { // scroll the first scroll view of the top controller to an offset
        UIViewController *top = [self topController];
        UIScrollView *sv = [top.view isKindOfClass:[UIScrollView class]] ? (UIScrollView *)top.view : nil;
        for (UIView *v in top.view.subviews) if (!sv && [v isKindOfClass:[UIScrollView class]]) sv = (UIScrollView *)v;
        CGFloat y = [params[@"y"] floatValue];
        [sv setContentOffset:CGPointMake(0, MIN(y, MAX(0, sv.contentSize.height - sv.bounds.size.height))) animated:NO];
        SHLog(@"scroll -> %@ y=%.0f of %.0f", NSStringFromClass([sv class]), sv.contentOffset.y, sv.contentSize.height);
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

#pragma mark - Debug helpers (only reached when a "debug" file exists in Documents)

// Renders every visible window (including alerts and action sheets, which use their own windows on iOS 6)
// into tmp/screen.png, where tools/ipad.ps1 reads it.
- (void)writeSnapshot
{
    CGSize size = [UIScreen mainScreen].bounds.size;
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.hidden || w.alpha < 0.01) continue;
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, w.center.x, w.center.y);
        CGContextConcatCTM(ctx, w.transform);
        CGContextTranslateCTM(ctx, -w.bounds.size.width * w.layer.anchorPoint.x, -w.bounds.size.height * w.layer.anchorPoint.y);
        [w.layer renderInContext:ctx];
        CGContextRestoreGState(ctx);
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    NSData *png = UIImagePNGRepresentation(img);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"screen.png"];
    [png writeToFile:path atomically:YES];
    SHLog(@"snapshot %ldx%ld -> %@ (%lu bytes)", (long)size.width, (long)size.height, path, (unsigned long)png.length);
}

// Fires the single-tap recognizers of a view the way a finger would, through UIKit's private target list
// (UIGestureRecognizer._targets of UIGestureRecognizerTarget {_target, _action}); story circles, grid thumbs and
// chat bubbles are reached this way. Debug builds only; a missing ivar just means nothing fires.
static BOOL SHDebugFireTapRecognizers(UIView *v)
{
    BOOL fired = NO;
    Ivar targetsIvar = class_getInstanceVariable([UIGestureRecognizer class], "_targets");
    if (!targetsIvar) return NO;
    for (UIGestureRecognizer *gr in v.gestureRecognizers) {
        if (![gr isKindOfClass:[UITapGestureRecognizer class]] || !gr.enabled) continue;
        if ([(UITapGestureRecognizer *)gr numberOfTapsRequired] != 1) continue;
        NSArray *targets = object_getIvar(gr, targetsIvar);
        for (id entry in targets) {
            Ivar tIvar = class_getInstanceVariable([entry class], "_target");
            Ivar aIvar = class_getInstanceVariable([entry class], "_action");
            if (!tIvar || !aIvar) continue;
            id target = object_getIvar(entry, tIvar);
            SEL action = *(SEL *)((char *)(__bridge void *)entry + ivar_getOffset(aIvar));   // a SEL, not an object: read raw
            if (!target || !action || ![target respondsToSelector:action]) continue;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [target performSelector:action withObject:gr];
#pragma clang diagnostic pop
            fired = YES;
        }
    }
    return fired;
}

// A best-effort synthetic tap for headless testing: hit-tests the point and triggers the tap recognizer, control
// or table row under it, nearest view first.
- (void)pressAtPoint:(CGPoint)pt
{
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    UIView *hit = [win hitTest:pt withEvent:nil];
    SHLog(@"press (%.0f,%.0f) -> %@", pt.x, pt.y, NSStringFromClass([hit class]));
    UIView *v = hit;
    while (v) {
        if (SHDebugFireTapRecognizers(v)) {
            SHLog(@"press -> tap recognizer of %@", NSStringFromClass([v class]));
            return;
        }
        if ([v isKindOfClass:[UIControl class]]) {
            [(UIControl *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
            return;
        }
        if ([v isKindOfClass:[UITableViewCell class]]) {
            UITableViewCell *cell = (UITableViewCell *)v;
            UITableView *table = nil;
            UIView *p = cell.superview;
            while (p && !table) { if ([p isKindOfClass:[UITableView class]]) table = (UITableView *)p; p = p.superview; }
            NSIndexPath *ip = table ? [table indexPathForCell:cell] : nil;
            if (table && ip && [table.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
                [table.delegate tableView:table didSelectRowAtIndexPath:ip];
            }
            return;
        }
        v = v.superview;
    }
}

@end
