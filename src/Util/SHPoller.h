#import <UIKit/UIKit.h>

// Instagram's own app hears about new messages over a live connection; this one asks again now and then instead.
// A poller asks while the app is in front and someone is using it: soon after something changed, then less and less
// often (up to the longest wait). Nothing runs while the app is in the background; after a long time without a
// touch it waits for the next touch. The block must call `done` once, saying whether it found anything new.
@interface SHPoller : NSObject
- (instancetype)initWithMinInterval:(NSTimeInterval)minInterval maxInterval:(NSTimeInterval)maxInterval
                              block:(void (^)(void (^done)(BOOL changed)))block;
- (void)start;                              // asks at once unless the last answer is newer than the shortest wait
- (void)startAfter:(NSTimeInterval)delay;
- (void)stop;
- (void)noteFresh;                          // the owner just loaded the same thing itself
- (void)speedUp;                            // something happened here (a message sent): the shortest wait again
@property (nonatomic, readonly) BOOL running;
@end

// The app's window: notes every touch, so that polling stops when nobody uses the app.
@interface SHActivityWindow : UIWindow
@end

void SHNoteUserActivity(void);
NSTimeInterval SHSecondsSinceUserActivity(void);
extern NSString * const SHUserReturnedNotification;   // the first touch after a pause of some minutes
