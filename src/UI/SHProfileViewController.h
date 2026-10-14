#import <UIKit/UIKit.h>

@interface SHProfileViewController : UIViewController
- (instancetype)initWithUsername:(NSString *)username pk:(NSString *)pk;
// The signed-in account's own profile: shows a settings button and a Saved shortcut, no Follow button, and
// falls back to the "current user" endpoint when the username/pk are not known yet.
@property (nonatomic) BOOL isCurrentUser;
@end
