#import <UIKit/UIKit.h>
@class SHPost, SHGridRowCell;

@protocol SHGridRowDelegate <NSObject>
- (void)gridRow:(SHGridRowCell *)row didTapPost:(SHPost *)post;
@end

// A single row of up to three square thumbnails, used by the Explore, Saved and profile grids.
@interface SHGridRowCell : UITableViewCell
@property (nonatomic, weak) id<SHGridRowDelegate> delegate;
+ (CGFloat)rowHeightForWidth:(CGFloat)width;     // a third of the width (square cells)
+ (NSUInteger)columns;
- (void)configureWithPosts:(NSArray *)posts;     // 1..3 SHPost
@end
