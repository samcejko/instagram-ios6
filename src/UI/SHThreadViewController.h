#import <UIKit/UIKit.h>
@class SHDirectThread;

// A single Direct conversation: the messages and a bar to send text, photos and voice messages. A message request
// (pendingRequest) shows Accept and Delete in place of the bar until it is answered.
@interface SHThreadViewController : UIViewController
- (instancetype)initWithThread:(SHDirectThread *)thread;
@property (nonatomic) BOOL pendingRequest;
@property (nonatomic, copy) void (^onRequestAnswered)(BOOL accepted);
@end
