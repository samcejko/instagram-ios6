#import "SHLinkRouter.h"
#import "SHProfileViewController.h"
#import "SHPostDetailViewController.h"
#import "SHGridViewController.h"
#import "SHInstagram.h"
#import "SHModels.h"
#import "SHExternalOpen.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHCommon.h"

@interface SHLinkChoice : NSObject <UIActionSheetDelegate>
@property (nonatomic, strong) NSArray *links;
@property (nonatomic, weak) UIViewController *controller;
@property (nonatomic, weak) UIView *anchor;
@property (nonatomic) NSInteger chosen;
@end

static NSMutableArray *g_choices;

@implementation SHLinkChoice

- (instancetype)init { if ((self = [super init])) _chosen = -1; return self; }

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index
{
    self.chosen = (index >= 0 && index != sheet.cancelButtonIndex && index < (NSInteger)self.links.count) ? index : -1;
}

- (void)actionSheet:(UIActionSheet *)sheet didDismissWithButtonIndex:(NSInteger)index
{
    sheet.delegate = nil;
    if (self.chosen >= 0) [SHLinkRouter openWebLink:[self.links objectAtIndex:(NSUInteger)self.chosen] from:self.controller anchor:self.anchor];
    SHLinkChoice *me = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [g_choices removeObject:me]; });
}

@end

// The first page of a navigation presented over the screen, never looked at: it gives the screen above it the bar's
// real back button ("< Reels"), and going back to it closes the whole navigation.
@interface SHBackAnchorController : UIViewController
@end

@implementation SHBackAnchorController
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [[SHTheme shared] linenColor];
}
@end

// A navigation presented over the screen: back from its first screen closes it, and its owner hears when it is gone
// (also when a screen in it closes it with its own Done button).
@interface SHModalNavigationController : UINavigationController <UINavigationControllerDelegate>
@property (nonatomic, copy) void (^onClose)(void);
@end

@implementation SHModalNavigationController

- (void)navigationController:(UINavigationController *)nav didShowViewController:(UIViewController *)vc animated:(BOOL)animated
{
    if ([vc isKindOfClass:[SHBackAnchorController class]] && !self.isBeingDismissed && self.presentingViewController)
        [self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    if (!self.isBeingDismissed || !self.onClose) return;
    void (^closed)(void) = self.onClose;
    self.onClose = nil;
    closed();
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end

@implementation SHLinkRouter

// The controller the user is looking at: through modal presentations, the selected tab and its navigation stack,
// so that a profile or post opened from a link is pushed where the user is instead of presented without a way back.
+ (UIViewController *)topController
{
    UIViewController *top = [UIApplication sharedApplication].keyWindow.rootViewController;
    for (;;) {
        if (top.presentedViewController) top = top.presentedViewController;
        else if ([top isKindOfClass:[UITabBarController class]]) top = [(UITabBarController *)top selectedViewController];
        else if ([top isKindOfClass:[UINavigationController class]]) top = [(UINavigationController *)top topViewController];
        else break;
    }
    return top;
}

+ (void)presentInNavigation:(UIViewController *)controller { [self presentInNavigation:controller onClose:nil]; }

+ (void)presentInNavigation:(UIViewController *)controller onClose:(void (^)(void))onClose
{
    UIViewController *top = [self topController];
    // the back button says where it goes: the screen underneath (the system's "Back" when it has no title)
    SHBackAnchorController *anchor = [[SHBackAnchorController alloc] init];
    NSString *under = top.navigationItem.title.length ? top.navigationItem.title : top.title;
    if (under.length) anchor.title = under;
    SHModalNavigationController *nav = [[SHModalNavigationController alloc] initWithRootViewController:anchor];
    [nav pushViewController:controller animated:NO];
    nav.delegate = nav;
    nav.onClose = onClose;
    [[SHTheme shared] applyToNavigationBar:nav.navigationBar];
    if (SHIsPad()) nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [top presentViewController:nav animated:YES completion:nil];
}

+ (BOOL)openLink:(NSString *)link
{
    NSString *s = [link stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    if (!s.length) return NO;
    if (![[s lowercaseString] hasPrefix:@"http"]) s = [@"https://" stringByAppendingString:s];
    NSURL *url = [NSURL URLWithString:s];
    NSString *host = [url.host lowercaseString] ?: @"";
    NSString *path = url.path ?: @"";
    if (![host isEqualToString:@"instagram.com"] && ![host hasSuffix:@".instagram.com"] && ![host isEqualToString:@"instagr.am"]) return NO;

    NSArray *parts = [[path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]] componentsSeparatedByString:@"/"];
    if (parts.count >= 2 && ([[[parts objectAtIndex:0] lowercaseString] isEqualToString:@"p"] || [[[parts objectAtIndex:0] lowercaseString] isEqualToString:@"reel"]
                             || [[[parts objectAtIndex:0] lowercaseString] isEqualToString:@"tv"])) {
        [self openPost:[parts objectAtIndex:1]];
        return YES;
    }
    if (parts.count >= 3 && [[[parts objectAtIndex:0] lowercaseString] isEqualToString:@"explore"] && [[[parts objectAtIndex:1] lowercaseString] isEqualToString:@"tags"]) {
        [self openHashtag:[parts objectAtIndex:2]];
        return YES;
    }
    if (parts.count >= 2 && [[[parts objectAtIndex:0] lowercaseString] isEqualToString:@"stories"]) {   // stories/<name>/<id>: whose they are
        [self openProfile:[parts objectAtIndex:1]];
        return YES;
    }
    if (parts.count >= 1 && [[parts objectAtIndex:0] length] && ![[[parts objectAtIndex:0] lowercaseString] isEqualToString:@"explore"]
        && ![[[parts objectAtIndex:0] lowercaseString] isEqualToString:@"about"] && ![[[parts objectAtIndex:0] lowercaseString] isEqualToString:@"accounts"]) {
        [self openProfile:[parts objectAtIndex:0]];
        return YES;
    }
    return NO;
}

+ (void)pushController:(UIViewController *)controller
{
    UIViewController *top = [self topController];
    UINavigationController *nav = [top isKindOfClass:[UINavigationController class]] ? (UINavigationController *)top : top.navigationController;
    if (nav) [nav pushViewController:controller animated:YES];
    else [self presentInNavigation:controller];
}

+ (void)openProfile:(NSString *)username { [self openProfileWithUsername:username pk:nil]; }

+ (void)openProfileWithUsername:(NSString *)username pk:(NSString *)pk
{
    NSString *name = [username hasPrefix:@"@"] ? [username substringFromIndex:1] : username;
    if (!name.length && !pk.length) return;
    [self pushController:[[SHProfileViewController alloc] initWithUsername:name pk:pk]];
}

+ (void)openHashtag:(NSString *)tag
{
    NSString *t = [tag hasPrefix:@"#"] ? [tag substringFromIndex:1] : tag;
    t = [t lowercaseString];
    if (!t.length) return;
    SHGridViewController *vc = [[SHGridViewController alloc] initWithTitle:[@"#" stringByAppendingString:t]
        loader:^SHHTTPTask *(NSString *maxId, SHFeedCompletion completion) {
            return [SHInstagram hashtagFeed:t maxId:maxId completion:completion];
        }];
    vc.emptyMessage = L(@"No posts with this hashtag yet.");
    [self pushController:vc];
}

// The numeric id of a post from the code in its link: the code is the id in base 64 (A-Z a-z 0-9 - _). A private
// post's long code starts with the same 11 characters.
static NSString *SHMediaPkFromShortcode(NSString *code)
{
    static NSString * const alphabet = @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    NSString *c = code.length > 11 ? [code substringToIndex:11] : code;
    unsigned long long pk = 0;
    for (NSUInteger i = 0; i < c.length; i++) {
        NSRange r = [alphabet rangeOfString:[c substringWithRange:NSMakeRange(i, 1)]];
        if (r.location == NSNotFound) return nil;
        pk = pk * 64 + r.location;
    }
    return pk ? [NSString stringWithFormat:@"%llu", pk] : nil;
}

+ (void)openPost:(NSString *)shortcode
{
    NSString *pk = SHMediaPkFromShortcode(shortcode);
    if (!pk) return;
    [SHInstagram mediaInfo:pk completion:^(SHPost *post, NSError *error) {
        if (!post.pk.length) {
            [SHUtils alertWithTitle:L(@"Post") message:error.localizedDescription ?: L(@"This post is no longer available.")];
            return;
        }
        [self pushController:[[SHPostDetailViewController alloc] initWithPost:post]];
    }];
}

#pragma mark - Web links in texts

+ (NSString *)webLinkString:(id)link
{
    NSString *s = [link isKindOfClass:[NSURL class]] ? [(NSURL *)link absoluteString] : [link isKindOfClass:[NSString class]] ? link : nil;
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length) return nil;
    if ([s rangeOfString:@"://"].location == NSNotFound) s = [@"https://" stringByAppendingString:s];
    return s;
}

+ (void)openWebLink:(id)link from:(UIViewController *)controller anchor:(UIView *)anchor
{
    NSString *s = [self webLinkString:link];
    if (!s) return;
    if ([self openLink:s]) return;
    NSURL *url = [NSURL URLWithString:s] ?: [NSURL URLWithString:[s stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: @""];
    if (!url) return;
    [SHExternalOpen presentOpenInForURL:url from:controller ?: [self topController] anchor:anchor];
}

+ (void)openWebLinks:(NSArray *)links from:(UIViewController *)controller anchor:(UIView *)anchor
{
    if (!links.count) return;
    if (links.count == 1) { [self openWebLink:[links objectAtIndex:0] from:controller anchor:anchor]; return; }
    SHLinkChoice *choice = [[SHLinkChoice alloc] init];
    choice.links = links;
    choice.controller = controller;
    choice.anchor = anchor;
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:L(@"Open a link") delegate:choice cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    for (id link in links) [sheet addButtonWithTitle:[SHUtils linkTitle:link length:60]];
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:L(@"Cancel")];
    if (!g_choices) g_choices = [NSMutableArray array];
    [g_choices addObject:choice];
    [SHExternalOpen showSheet:sheet from:controller ?: [self topController] anchor:anchor];
}

@end
