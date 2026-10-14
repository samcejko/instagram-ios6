#import "SHLinkRouter.h"
#import "SHProfileViewController.h"
#import "SHPostDetailViewController.h"
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
    if (self.chosen >= 0) [SHLinkRouter openWebLink:self.links[(NSUInteger)self.chosen] from:self.controller anchor:self.anchor];
    SHLinkChoice *me = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [g_choices removeObject:me]; });
}

@end

@implementation SHLinkRouter

+ (UIViewController *)topController
{
    UIViewController *top = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

+ (void)presentInNavigation:(UIViewController *)controller
{
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
    [[SHTheme shared] applyToNavigationBar:nav.navigationBar];
    if (SHIsPad()) nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [[self topController] presentViewController:nav animated:YES completion:nil];
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
    if (parts.count >= 2 && ([[parts[0] lowercaseString] isEqualToString:@"p"] || [[parts[0] lowercaseString] isEqualToString:@"reel"])) {
        [self openPost:parts[1]];
        return YES;
    }
    if (parts.count >= 1 && [parts[0] length] && ![[parts[0] lowercaseString] isEqualToString:@"explore"]
        && ![[parts[0] lowercaseString] isEqualToString:@"about"] && ![[parts[0] lowercaseString] isEqualToString:@"accounts"]) {
        [self openProfile:parts[0]];
        return YES;
    }
    return NO;
}

+ (void)openProfile:(NSString *)username
{
    NSString *name = username;
    if ([name hasPrefix:@"@"]) name = [name substringFromIndex:1];
    if (!name.length) return;
    SHProfileViewController *vc = [[SHProfileViewController alloc] initWithUsername:name pk:nil];
    UIViewController *top = [self topController];
    if ([top isKindOfClass:[UINavigationController class]]) {
        [(UINavigationController *)top pushViewController:vc animated:YES];
    } else if (top.navigationController) {
        [top.navigationController pushViewController:vc animated:YES];
    } else {
        [self presentInNavigation:vc];
    }
}

+ (void)openPost:(NSString *)shortcode
{
    // Resolve post by shortcode - for now just log; full resolution needs media_id from shortcode
    SHLog(@"Open post %@", shortcode);
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
    if (links.count == 1) { [self openWebLink:links[0] from:controller anchor:anchor]; return; }
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
