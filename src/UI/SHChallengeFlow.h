#import <UIKit/UIKit.h>

// Walks Instagram's checkpoint ("challenge") steps with the stock alerts: the choice of e-mail or SMS, the code,
// a "was this you?" login review, or the plain acknowledgement of an unusual-activity notice. Used after a login
// that ends in SHErrorChallenge and when a live session is stopped with challenge_required. One flow runs at a
// time; `passed` is YES once Instagram closed the checkpoint.
@interface SHChallengeFlow : NSObject
+ (BOOL)isRunning;
+ (void)startInView:(UIView *)view completion:(void (^)(BOOL passed, NSError *error))completion;
@end
