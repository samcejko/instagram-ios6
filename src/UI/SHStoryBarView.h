#import <UIKit/UIKit.h>

@class SHStoryReel, SHStoryBarView;

@protocol SHStoryBarDelegate <NSObject>
- (void)storyBar:(SHStoryBarView *)bar didSelectReel:(SHStoryReel *)reel atIndex:(NSUInteger)index;
@end

@interface SHStoryBarView : UIView
@property (nonatomic, weak) id<SHStoryBarDelegate> delegate;
@property (nonatomic, strong, readonly) NSArray *reels;
- (void)setReels:(NSArray *)reels;
@end
