#import <UIKit/UIKit.h>
#import "SHGridViewController.h"

// Reels as the app shows them: one video per screen, swiped up and down, playing on its own and looping, with
// the person, the caption and glossy round buttons (like, comment, the post) over it. Pages come from the loader.
@interface SHReelsViewController : UIViewController
- (instancetype)initWithLoader:(SHGridLoader)loader;
@end
