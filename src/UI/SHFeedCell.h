#import <UIKit/UIKit.h>

@class SHPost, SHFeedCell;

@protocol SHFeedCellDelegate <NSObject>
- (void)feedCell:(SHFeedCell *)cell didTapUser:(NSString *)pk username:(NSString *)username;
- (void)feedCell:(SHFeedCell *)cell didTapLikeOnPost:(SHPost *)post;
- (void)feedCell:(SHFeedCell *)cell didTapCommentOnPost:(SHPost *)post;
- (void)feedCell:(SHFeedCell *)cell didTapImageOnPost:(SHPost *)post;
@end

@interface SHFeedCell : UITableViewCell
@property (nonatomic, weak) id<SHFeedCellDelegate> delegate;
@property (nonatomic, strong, readonly) SHPost *post;
- (void)configureWithPost:(SHPost *)post;
+ (CGFloat)heightForPost:(SHPost *)post width:(CGFloat)width;
@end
