#import "SHExternalOpen.h"
#import "SHUtils.h"
#import "SHModern.h"
#import "SHCommon.h"

// What each button of the chooser does, in the order the buttons were added
typedef enum { SHOpenCopy, SHOpenSister, SHOpenSafari, SHOpenSurfari } SHOpenAction;

@interface SHExternalOpen () <UIActionSheetDelegate>
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSArray *actions;      // NSNumber (SHOpenAction) per button
@end

// The live sheets' delegates (UIActionSheet does not retain its delegate), so ARC does not free them while the sheet
// is on screen
static NSMutableArray *g_live;

// Paths under twitch.tv that are not a channel's name
static NSArray *SHTwitchReservedPaths(void)
{
    return @[ @"directory", @"videos", @"search", @"settings", @"downloads", @"p", @"jobs", @"turbo", @"friends", @"subscriptions",
              @"inventory", @"wallet", @"drops", @"prime", @"team", @"moderator", @"login", @"signup", @"products", @"store",
              @"legal", @"privacy", @"creatorcamp", @"embed", @"popout", @"collections", @"events", @"bits" ];
}

// A Twitch login: 3-25 letters, digits and underscores
static BOOL SHLooksLikeTwitchLogin(NSString *s)
{
    if (s.length < 3 || s.length > 25) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789_"];
    return [s rangeOfCharacterFromSet:[allowed invertedSet]].location == NSNotFound;
}

// The sister app's own link for a web link, and the app's name: tubie:open?url=…, kicker:open?url=… and, as Twitcher
// has no open?url, its channel, video and clip links built from the twitch.tv address. nil when no sister app applies.
static NSURL *SHSisterURL(NSURL *url, NSString **name)
{
    NSString *host = [url.host lowercaseString] ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    NSString *encoded = [SHUtils urlEncode:url.absoluteString ?: @""];
    if ([host isEqualToString:@"youtube.com"] || [host hasSuffix:@".youtube.com"] || [host isEqualToString:@"youtu.be"] ||
        [host isEqualToString:@"youtube-nocookie.com"] || [host hasSuffix:@".youtube-nocookie.com"]) {
        if (name) *name = @"Tubie";
        return [NSURL URLWithString:[@"tubie:open?url=" stringByAppendingString:encoded]];
    }
    if ([host isEqualToString:@"kick.com"] || [host hasSuffix:@".kick.com"]) {
        if (name) *name = @"Kicker";
        return [NSURL URLWithString:[@"kicker:open?url=" stringByAppendingString:encoded]];
    }
    if ([host isEqualToString:@"twitch.tv"] || [host hasSuffix:@".twitch.tv"]) {
        NSArray *parts = [[url.path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]] componentsSeparatedByString:@"/"];
        NSString *first = parts.count ? [parts[0] lowercaseString] : @"";
        NSString *target = nil;
        if ([host isEqualToString:@"clips.twitch.tv"]) {
            if (first.length) target = [@"twitcher:clip/" stringByAppendingString:parts[0]];
        } else if ([first isEqualToString:@"videos"]) {
            if (parts.count > 1 && [parts[1] length]) target = [@"twitcher:video/" stringByAppendingString:parts[1]];
        } else if (parts.count > 2 && [[parts[1] lowercaseString] isEqualToString:@"clip"]) {
            if ([parts[2] length]) target = [@"twitcher:clip/" stringByAppendingString:parts[2]];
        } else if (SHLooksLikeTwitchLogin(first) && ![SHTwitchReservedPaths() containsObject:first]) {
            target = [@"twitcher:channel/" stringByAppendingString:first];
        }
        if (!target) return nil;
        if (name) *name = @"Twitcher";
        return [NSURL URLWithString:target];
    }
    return nil;
}

static NSString *SHSisterTitle(NSString *name)
{
    if ([name isEqualToString:@"Tubie"]) return L(@"Open in Tubie");
    if ([name isEqualToString:@"Twitcher"]) return L(@"Open in Twitcher");
    return L(@"Open in Kicker");
}

@implementation SHExternalOpen

#pragma mark - Where a link can go

+ (BOOL)surfariAvailable
{
    return [[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"surfari://open?url=https://www.tiktok.com/"]];
}

+ (NSURL *)surfariURLForURL:(NSURL *)url
{
    NSString *encoded = [SHUtils urlEncode:url.absoluteString ?: @""];
    return [NSURL URLWithString:[@"surfari://open?url=" stringByAppendingString:encoded]];
}

+ (NSString *)sisterAppForURL:(NSURL *)url
{
    NSString *name = nil;
    NSURL *target = SHSisterURL(url, &name);
    if (!target || ![[UIApplication sharedApplication] canOpenURL:target]) return nil;
    return name;
}

+ (BOOL)isWebURL:(NSURL *)url { return url && [[url.scheme lowercaseString] hasPrefix:@"http"]; }

+ (void)openInSafari:(NSURL *)url
{
    if ([self isWebURL:url]) [[UIApplication sharedApplication] openURL:url];
}

+ (void)openInSurfari:(NSURL *)url
{
    if (![self isWebURL:url]) return;
    [[UIApplication sharedApplication] openURL:[self surfariAvailable] ? [self surfariURLForURL:url] : url];
}

+ (BOOL)openInSisterApp:(NSURL *)url
{
    NSURL *target = SHSisterURL(url, NULL);
    if (!target || ![[UIApplication sharedApplication] canOpenURL:target]) return NO;
    return [[UIApplication sharedApplication] openURL:target];
}

#pragma mark - The chooser

+ (void)presentShareSheetForURL:(NSURL *)url from:(UIViewController *)controller anchor:(UIView *)anchor
{
    [self present:url copy:YES from:controller anchor:anchor];
}

+ (void)presentOpenInForURL:(NSURL *)url from:(UIViewController *)controller anchor:(UIView *)anchor
{
    [self present:url copy:NO from:controller anchor:anchor];
}

+ (void)present:(NSURL *)url copy:(BOOL)copy from:(UIViewController *)controller anchor:(UIView *)anchor
{
    if (![self isWebURL:url]) return;
    NSString *sister = [self sisterAppForURL:url];
    if (SHModernIOS()) {
        // iOS 7 and newer: no chooser of browsers - the system opens the link, the system's sheet shares it; a sheet
        // only when a sister app could take the link
        if (copy) { [self presentSystemShareSheetForURL:url from:controller anchor:anchor]; return; }
        if (!sister) { [self openInSafari:url]; return; }
    }
    SHExternalOpen *open = [[SHExternalOpen alloc] init];
    open.url = url;
    NSMutableArray *actions = [NSMutableArray array];
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:url.absoluteString delegate:open cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    if (copy) { [sheet addButtonWithTitle:L(@"Copy link")]; [actions addObject:@(SHOpenCopy)]; }
    if (sister) { [sheet addButtonWithTitle:SHSisterTitle(sister)]; [actions addObject:@(SHOpenSister)]; }
    [sheet addButtonWithTitle:L(@"Open in Safari")];
    [actions addObject:@(SHOpenSafari)];
    if (!SHModernIOS() && [self surfariAvailable]) { [sheet addButtonWithTitle:L(@"Open in Surfari")]; [actions addObject:@(SHOpenSurfari)]; }
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:L(@"Cancel")];
    open.actions = actions;
    if (!g_live) g_live = [NSMutableArray array];
    [g_live addObject:open];
    [self showSheet:sheet from:controller anchor:anchor];
}

+ (void)showSheet:(UIActionSheet *)sheet from:(UIViewController *)controller anchor:(UIView *)anchor
{
    if (SHIsPad() && anchor.window) { [sheet showFromRect:anchor.bounds inView:anchor animated:YES]; return; }
    UIView *host = controller.view.window ? controller.view : anchor.window ? anchor : nil;
    if (!host) host = [UIApplication sharedApplication].keyWindow.rootViewController.view;
    // the view that fills the screen: the sheet shown in a smaller view (a panel, the comments sheet) would be cut by it
    while (host.superview && ![host.superview isKindOfClass:[UIWindow class]]) host = host.superview;
    if (host) [sheet showInView:host];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index
{
    if (index < 0 || index == sheet.cancelButtonIndex || index >= (NSInteger)self.actions.count) return;
    switch ((SHOpenAction)[self.actions[(NSUInteger)index] integerValue]) {
        case SHOpenCopy: [UIPasteboard generalPasteboard].string = self.url.absoluteString; break;
        case SHOpenSister: if (![SHExternalOpen openInSisterApp:self.url]) [SHExternalOpen openInSafari:self.url]; break;
        case SHOpenSafari: [SHExternalOpen openInSafari:self.url]; break;
        case SHOpenSurfari: [SHExternalOpen openInSurfari:self.url]; break;
    }
}

// The last word from the sheet: let go of the delegate afterwards, not in its own hands (the sheet's delegate
// reference is unretained)
- (void)actionSheet:(UIActionSheet *)sheet didDismissWithButtonIndex:(NSInteger)index
{
    sheet.delegate = nil;
    SHExternalOpen *me = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [g_live removeObject:me]; });
}

#pragma mark - iOS 7 and newer: the system's share sheet

// Only reached on iOS 7 and newer (SHModernIOS() checked by the caller). The APIs newer than iOS 6 here are behind
// the SDK check and run only on an iOS that has them, so the availability error of SHCommon.h is off for this part.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"

static UIPopoverController *g_popover;   // iOS 7 on an iPad: the popover around the share sheet, kept until it is gone

+ (void)presentSystemShareSheetForURL:(NSURL *)url from:(UIViewController *)controller anchor:(UIView *)anchor
{
    UIViewController *presenter = controller ?: [UIApplication sharedApplication].keyWindow.rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter) { [self openInSafari:url]; return; }
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[ url ] applicationActivities:nil];
    UIView *source = anchor.window ? anchor : presenter.view;
    CGRect rect = anchor.window ? anchor.bounds : CGRectMake(floorf(CGRectGetMidX(source.bounds)), floorf(CGRectGetMidY(source.bounds)), 1, 1);
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 80000
    if ([activity respondsToSelector:@selector(popoverPresentationController)]) {
        // iOS 8 and newer: the iPad wants a popover and tells it where through this (nil on the iPhone)
        UIPopoverPresentationController *popover = activity.popoverPresentationController;
        popover.sourceView = source;
        popover.sourceRect = rect;
        [presenter presentViewController:activity animated:YES completion:nil];
        return;
    }
#endif
    if (SHIsPad()) {
        // iOS 7 on an iPad: the sheet has to sit in a popover of its own
        UIPopoverController *popover = [[UIPopoverController alloc] initWithContentViewController:activity];
        g_popover = popover;
        __weak UIPopoverController *weakPopover = popover;
        activity.completionHandler = ^(NSString *activityType, BOOL completed) {
            [weakPopover dismissPopoverAnimated:YES];
            if (g_popover == weakPopover) g_popover = nil;
        };
        [popover presentPopoverFromRect:rect inView:source permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
        return;
    }
    [presenter presentViewController:activity animated:YES completion:nil];
}

#pragma clang diagnostic pop

@end
