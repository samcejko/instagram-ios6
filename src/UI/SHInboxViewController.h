#import <UIKit/UIKit.h>

// The Direct tab: a list of conversations, with "Message requests (n)" on top when some wait. The same list in
// pending mode shows the message requests themselves.
@interface SHInboxViewController : UIViewController
- (instancetype)initWithPendingRequests;
@end
