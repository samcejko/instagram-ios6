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
// Over the screen, in a navigation of its own whose first screen has the bar's back button (it closes the whole
// navigation); `onClose` runs once it is gone.
+ (void)presentInNavigation:(UIViewController *)controller;
+ (void)presentInNavigation:(UIViewController *)controller onClose:(void (^)(void))onClose;
@end
