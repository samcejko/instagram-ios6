#import "SHAppDelegate.h"
#import "SHLoginViewController.h"
#import "SHFeedViewController.h"
#import "SHMainTabController.h"
#import "SHChallengeFlow.h"
#import "SHLinkRouter.h"
#import "SHThreadViewController.h"
#import "SHInstagram.h"
#import "SHMediaProxy.h"
#import "SHRealtime.h"
#import "SHTLSSocket.h"
#import "SHImageLoader.h"
#import "SHSettings.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHModern.h"
#import "SHPoller.h"
#import "SHSounds.h"
#import "SHCommon.h"
#import <QuartzCore/QuartzCore.h>
#include <objc/runtime.h>
#include <signal.h>

#define SH_ALERT_CHECKPOINT 500

static UIView *SHDebugFindView(UIView *root, Class cls, NSInteger index, BOOL outsideSearchBars);

@interface SHAppDelegate () <UIAlertViewDelegate>
@property (nonatomic) BOOL checkpointPromptUp;       // one alert for the burst of failing calls, not one each
@property (nonatomic) NSTimeInterval checkpointDismissedAt;
@property (nonatomic) BOOL sessionEndHandled;           // a dead session goes back to the login screen once
@end

@implementation SHAppDelegate

+ (instancetype)shared { return (SHAppDelegate *)[UIApplication sharedApplication].delegate; }

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    signal(SIGPIPE, SIG_IGN);
    [SHSettings registerDefaults];
    [SHInstagram registerChallengeObserver];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(challengeRequired:)
                                                 name:SHHTTPChallengeRequiredNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(loginRequired:)
                                                 name:SHHTTPLoginRequiredNotification object:nil];
    [SHSounds startObservingLiveMessages];   // (the sound of a message that comes in)
    // iOS 6 UILabels default to an opaque (white) background, which shows as boxes behind text on the dark theme.
    // Make the default transparent app-wide; labels that need a fill (chat bubbles) set their colour explicitly.
    [[UILabel appearance] setBackgroundColor:[UIColor clearColor]];
    SHLog(@"Gramify %@ starting on %@ (iOS %@)", [SHUtils appVersion], [SHUtils deviceModel],
          [UIDevice currentDevice].systemVersion);
    SHModernSetUp([[SHTheme shared] barStyle]);
    [SHTLSSocket warmUp];
    [[SHImageLoader shared] pruneDisk];

    self.window = [[SHActivityWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];   // (notes touches: polling)
    self.window.backgroundColor = [UIColor blackColor];

    // A kept session token that is not a whole one (cut by an older version's sign-in) is no session: the login
    // screen, not an app whose every screen says "Your session expired".
    if ([SHSettings isLoggedIn] && ![SHInstagram hasUsableSessionToken]) {
        SHLog(@"The kept session token is not a whole one: logged out");
        [SHSettings logout];
    }
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
    self.sessionEndHandled = NO;
    self.window.rootViewController = [[SHMainTabController alloc] init];
}

- (UIViewController *)topController
{
    UIViewController *top = self.window.rootViewController;
    for (;;) {
        if (top.presentedViewController) top = top.presentedViewController;
        else if ([top isKindOfClass:[UITabBarController class]]) top = [(UITabBarController *)top selectedViewController];
        else if ([top isKindOfClass:[UINavigationController class]]) top = [(UINavigationController *)top topViewController];
        else break;
    }
    return top;
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation
{
    SHNoteUserActivity();   // (a link opened here, or a debug command, is using the app)
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
    if ([target isEqualToString:@"open"] && [[params objectForKey:@"url"] length]) {
        if (![SHLinkRouter openLink:[params objectForKey:@"url"]]) [SHUtils alertWithTitle:L(@"Open a link") message:L(@"That does not look like an Instagram link.")];
        return YES;
    }

    BOOL debug = [[NSFileManager defaultManager] fileExistsAtPath:[[SHUtils documentsPath] stringByAppendingPathComponent:@"debug"]];
    if (!debug) return YES;

    if ([target isEqualToString:@"stats"]) {
        SHLog(@"Top: %@, proxy %@", NSStringFromClass([[self topController] class]), [[SHMediaProxy shared] statsDescription]);
        return YES;
    }
    if ([target isEqualToString:@"rt"]) {
        // the live connection: its state; off=1 stops it (polling only, as when it fails), on=1 starts it again
        if ([[params objectForKey:@"off"] boolValue]) [[SHRealtime shared] stop];
        if ([[params objectForKey:@"on"] boolValue] && [SHSettings isLoggedIn]) {
            [[SHRealtime shared] start];
            [SHInstagram directInboxWithCursor:nil completion:nil];   // (its seq_id starts the connection)
        }
        SHLog(@"RT %@", [[SHRealtime shared] statusLine]);
        return YES;
    }
    if ([target isEqualToString:@"thread"]) {
        // a chat of the inbox's first page opened by its id on the Direct tab (as a tap on its row would)
        NSString *threadId = [params objectForKey:@"id"] ?: @"";
        [SHInstagram directInboxWithCursor:nil completion:^(NSArray *threads, NSString *cursor, NSError *error) {
            SHDirectThread *found = nil;
            for (SHDirectThread *t in threads) if ([t.threadId isEqualToString:threadId]) found = t;
            UIViewController *root = self.window.rootViewController;
            if (!found || ![root isKindOfClass:[UITabBarController class]]) {
                SHLog(@"thread -> %@", found ? @"no tab shell" : (error ? error.localizedDescription : @"not on the inbox's first page"));
                return;
            }
            UITabBarController *tabs = (UITabBarController *)root;
            tabs.selectedIndex = 3;
            UINavigationController *nav = (UINavigationController *)tabs.selectedViewController;
            if (![nav isKindOfClass:[UINavigationController class]]) return;
            [nav popToRootViewControllerAnimated:NO];
            [nav pushViewController:[[SHThreadViewController alloc] initWithThread:found] animated:YES];
            SHLog(@"thread -> opened, %lu users", (unsigned long)found.users.count);
        }];
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
    if ([target isEqualToString:@"newdevice"]) {
        // a new device in Instagram's eyes for the next sign-in (the code it asks a new device for); logged out only
        if ([SHSettings isLoggedIn]) { SHLog(@"newdevice: log out first"); return YES; }
        [SHSettings renewDeviceIds];
        SHLog(@"newdevice: new device ids");
        return YES;
    }
    if ([target isEqualToString:@"showtabs"]) {
        [self showFeed];   // the main tab shell, even without a session, to inspect the layout
        return YES;
    }
    if ([target isEqualToString:@"tab"]) {
        NSInteger idx = [[params objectForKey:@"i"] integerValue];
        UIViewController *root = self.window.rootViewController;
        if ([root isKindOfClass:[UITabBarController class]] && idx >= 0 && idx < (NSInteger)[(UITabBarController *)root viewControllers].count)
            [(UITabBarController *)root setSelectedIndex:idx];
        return YES;
    }
    if ([target isEqualToString:@"press"]) {
        CGPoint pt = CGPointMake([[params objectForKey:@"x"] floatValue], [[params objectForKey:@"y"] floatValue]);
        [self pressAtPoint:pt];
        return YES;
    }
    if ([target isEqualToString:@"type"]) {
        // text into the top screen as if typed: in=search (the search bar, default) or in=field&n=<index> (its text
        // fields outside search bars, in view order); submit=1 also presses Search / Return
        UIViewController *top = [self topController];
        NSString *text = [params objectForKey:@"text"] ?: @"";
        BOOL submit = [[params objectForKey:@"submit"] boolValue];
        if (![[params objectForKey:@"in"] isEqualToString:@"field"]) {
            UISearchBar *bar = (UISearchBar *)SHDebugFindView(top.view, [UISearchBar class], 0, NO);
            if (bar) {
                bar.text = text;
                if ([bar.delegate respondsToSelector:@selector(searchBar:textDidChange:)]) [bar.delegate searchBar:bar textDidChange:text];
                if (submit && [bar.delegate respondsToSelector:@selector(searchBarSearchButtonClicked:)]) [bar.delegate searchBarSearchButtonClicked:bar];
            }
            SHLog(@"type -> search bar %@ of %@", bar ? @"found" : @"missing", NSStringFromClass([top class]));
            return YES;
        }
        UITextField *field = (UITextField *)SHDebugFindView(top.view, [UITextField class], [[params objectForKey:@"n"] integerValue], YES);
        if (field) {
            field.text = text;
            if (submit && [field.delegate respondsToSelector:@selector(textFieldShouldReturn:)]) [field.delegate textFieldShouldReturn:field];
        }
        SHLog(@"type -> text field %@ of %@", field ? @"found" : @"missing", NSStringFromClass([top class]));
        return YES;
    }
    if ([target isEqualToString:@"alert"]) {
        // the alert on screen answered with button n (default: its cancel button); iOS 6 alerts live in a window of
        // their own that press cannot reach
        NSInteger n = [params objectForKey:@"n"] ? [[params objectForKey:@"n"] integerValue] : -1;
        UIAlertView *alert = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            NSInteger first = 0;
            UIView *found = SHDebugFindView(w, [UIAlertView class], first, NO);
            if (found) { alert = (UIAlertView *)found; break; }
        }
        if (alert) {
            NSInteger index = n >= 0 ? n : alert.cancelButtonIndex;
            if ([alert.delegate respondsToSelector:@selector(alertView:clickedButtonAtIndex:)]) [alert.delegate alertView:alert clickedButtonAtIndex:index];
            [alert dismissWithClickedButtonIndex:index animated:YES];
        }
        SHLog(@"alert -> %@", alert ? alert.title : @"none on screen");
        return YES;
    }
    if ([target isEqualToString:@"dmtestphoto"]) {   // a plain test picture waiting to be sent in the open chat
        UIViewController *top = [self topController];
        SEL attach = NSSelectorFromString(@"debugAttachTestPhoto");
        if ([top respondsToSelector:attach]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [top performSelector:attach];
#pragma clang diagnostic pop
        }
        SHLog(@"dmtestphoto -> %@", NSStringFromClass([top class]));
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
        CGFloat y = [[params objectForKey:@"y"] floatValue];
        [sv setContentOffset:CGPointMake(0, MIN(y, MAX(0, sv.contentSize.height - sv.bounds.size.height))) animated:NO];
        SHLog(@"scroll -> %@ y=%.0f of %.0f", NSStringFromClass([sv class]), sv.contentOffset.y, sv.contentSize.height);
        return YES;
    }
    if ([target isEqualToString:@"lang"]) {
        NSString *set = [params objectForKey:@"set"] ?: @"system";
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

#pragma mark - A session Instagram no longer takes

// Every call answers login_required (logged out on another device, a password change, a sign-in Instagram did not
// keep, or no session at all): back to the login screen once, with Instagram's own words when it gave any, instead
// of an app whose every screen says "Your session expired". (During the sign-in itself the login screen handles it.)
- (void)loginRequired:(NSNotification *)note
{
    if (self.sessionEndHandled) return;
    if (![self.window.rootViewController isKindOfClass:[SHMainTabController class]]) return;
    self.sessionEndHandled = YES;
    NSDictionary *json = SHDict([note.userInfo objectForKey:@"json"]);
    NSString *title = SHStr([json objectForKey:@"error_title"]);
    NSString *body = SHStr([json objectForKey:@"error_body"]);
    NSString *reason = SHStr([json objectForKey:@"logout_reason"]);
    NSInteger status = [[note.userInfo objectForKey:@"status"] integerValue];
    SHLog(@"Session ended by Instagram (HTTP %ld, logout_reason %@, had a session: %@)", (long)status, reason ?: @"-",
          [SHSettings isLoggedIn] ? @"yes" : @"no");
    [SHInstagram clearResponseCache];
    [SHSettings logout];
    [self showLogin];
    NSString *message = body.length ? body : L(@"Your session expired. Please log in again.");
    // (what Instagram said in numbers: a screenshot of this alert then tells why)
    if (reason.length) message = [message stringByAppendingFormat:@" (HTTP %ld, %@ %@)", (long)status, L(@"Reason"), reason];
    else if (status) message = [message stringByAppendingFormat:@" (HTTP %ld)", (long)status];
    [SHUtils alertWithTitle:title.length ? title : L(@"Log In") message:message];
}

#pragma mark - Security check of a live session

// Instagram stopped the session (every call answers challenge_required): offer the verification once, not for each
// of the calls that just failed, and not again for a while after the user declined.
- (void)challengeRequired:(NSNotification *)note
{
    if (![SHSettings isLoggedIn]) return;   // a checkpoint during the login is the login screen's business
    if (_checkpointPromptUp || [SHChallengeFlow isRunning]) return;
    if ([NSDate timeIntervalSinceReferenceDate] - _checkpointDismissedAt < 120) return;
    _checkpointPromptUp = YES;
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:L(@"Verify it's you")
        message:L(@"Instagram asked for a security check. Verify here with a code sent to your e-mail or phone, or confirm it in the Instagram app or on instagram.com and try again.")
        delegate:self cancelButtonTitle:L(@"Cancel") otherButtonTitles:L(@"Verify"), nil];
    alert.tag = SH_ALERT_CHECKPOINT;
    [alert show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (alertView.tag != SH_ALERT_CHECKPOINT) return;
    _checkpointPromptUp = NO;
    if (buttonIndex == alertView.cancelButtonIndex) { _checkpointDismissedAt = [NSDate timeIntervalSinceReferenceDate]; return; }
    [SHChallengeFlow startInView:self.window.rootViewController.view completion:^(BOOL passed, NSError *error) {
        if (passed) {
            [SHUtils alertWithTitle:L(@"Verify it's you") message:L(@"Verified. Loading again.")];
            [self showFeed];   // a fresh tab shell: every screen loads again with the checkpoint gone
            return;
        }
        self->_checkpointDismissedAt = [NSDate timeIntervalSinceReferenceDate];
        if (error) [SHUtils alertWithTitle:L(@"Verify it's you") message:error.localizedDescription];
    }];
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

// The index-th visible view of a class under root, depth first in view order (text fields inside a search bar are
// skipped when outsideSearchBars is set). Debug builds only.
static UIView *SHDebugFindViewIn(UIView *root, Class cls, NSInteger *index, BOOL outsideSearchBars)
{
    if (root.hidden || root.alpha < 0.01) return nil;
    if (outsideSearchBars && [root isKindOfClass:[UISearchBar class]]) return nil;
    if ([root isKindOfClass:cls]) {
        if (*index == 0) return root;
        (*index)--;
    }
    for (UIView *sub in root.subviews) {
        UIView *found = SHDebugFindViewIn(sub, cls, index, outsideSearchBars);
        if (found) return found;
    }
    return nil;
}

static UIView *SHDebugFindView(UIView *root, Class cls, NSInteger index, BOOL outsideSearchBars)
{
    NSInteger left = MAX(0, index);
    return SHDebugFindViewIn(root, cls, &left, outsideSearchBars);
}

// A best-effort synthetic tap for headless testing: hit-tests the point and triggers the tap recognizer, control
// or table row under it, nearest view first.
- (void)pressAtPoint:(CGPoint)pt
{
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    UIView *hit = [win hitTest:pt withEvent:nil];
    SHLog(@"press (%.0f,%.0f) -> %@", pt.x, pt.y, NSStringFromClass([hit class]));
    // On iOS 6 the hit is a private control inside UISwitch. Find the public
    // switch before dispatching a button event to that internal control.
    for (UIView *ancestor = hit; ancestor; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:[UISwitch class]]) {
            UISwitch *control = (UISwitch *)ancestor;
            [control setOn:!control.on animated:YES];
            [control sendActionsForControlEvents:UIControlEventValueChanged];
            return;
        }
    }
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
