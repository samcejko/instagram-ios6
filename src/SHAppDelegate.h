#import <UIKit/UIKit.h>

@interface SHAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
+ (instancetype)shared;
- (UIViewController *)topController;
- (void)showLogin;
- (void)showFeed;
@end
