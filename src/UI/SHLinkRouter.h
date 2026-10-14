#import <UIKit/UIKit.h>

@interface SHLinkRouter : NSObject
+ (BOOL)openLink:(NSString *)link;
+ (void)openProfile:(NSString *)username;
+ (void)openPost:(NSString *)shortcode;
+ (void)openWebLink:(id)link from:(UIViewController *)controller anchor:(UIView *)anchor;
+ (void)openWebLinks:(NSArray *)links from:(UIViewController *)controller anchor:(UIView *)anchor;
+ (UIViewController *)topController;
+ (void)presentInNavigation:(UIViewController *)controller;
@end
