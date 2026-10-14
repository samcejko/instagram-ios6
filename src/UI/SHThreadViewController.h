#import <UIKit/UIKit.h>
@class SHDirectThread;

// A single Direct conversation: the messages and a bar to send text.
@interface SHThreadViewController : UIViewController
- (instancetype)initWithThread:(SHDirectThread *)thread;
@end
