#import <UIKit/UIKit.h>

@class SHStoryReel, SHUser;

// Full-screen stories of the tray, from the tapped person on: a progress bar per story, the person's picture and
// name at the top (they open the profile), taps left and right to go back and on, a swipe down to close. Each reel
// starts at the first story not seen yet; what was seen is told to Instagram as the app does.
@interface SHStoryViewController : UIViewController
- (instancetype)initWithReels:(NSArray *)reels startIndex:(NSUInteger)index;
@property (nonatomic, copy) void (^onOpenProfile)(SHUser *user);   // after the viewer closed itself
@property (nonatomic, copy) void (^onClose)(void);                 // after it is gone (the tray can re-sort)
@end
