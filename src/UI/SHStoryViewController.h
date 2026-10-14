#import <UIKit/UIKit.h>

@class SHStoryReel;

@interface SHStoryViewController : UIViewController
- (instancetype)initWithReels:(NSArray *)reels startIndex:(NSUInteger)index;
@end
