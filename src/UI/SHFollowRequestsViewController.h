#import <UIKit/UIKit.h>

// "Follow requests": the people asking to follow this private account, each with Confirm and Delete.
@interface SHFollowRequestsViewController : UIViewController
@property (nonatomic, copy) void (^onChange)(void);   // a request was answered (the Activity list can reload)
@end
