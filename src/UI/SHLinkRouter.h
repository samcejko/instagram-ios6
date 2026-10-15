#import <UIKit/UIKit.h>

@interface SHLinkRouter : NSObject
+ (BOOL)openLink:(NSString *)link;
+ (void)openProfile:(NSString *)username;
+ (void)openProfileWithUsername:(NSString *)username pk:(NSString *)pk;
+ (void)openHashtag:(NSString *)tag;     // the tag's posts ("#" may be left on)
+ (void)openPost:(NSString *)shortcode;  // instagram.com/p/<shortcode>
+ (void)pushController:(UIViewController *)controller;   // where the user is (a navigation), else presented in one
+ (void)openWebLink:(id)link from:(UIViewController *)controller anchor:(UIView *)anchor;
+ (void)openWebLinks:(NSArray *)links from:(UIViewController *)controller anchor:(UIView *)anchor;
+ (UIViewController *)topController;
+ (void)presentInNavigation:(UIViewController *)controller;
@end
