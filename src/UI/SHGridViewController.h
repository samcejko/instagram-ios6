#import <UIKit/UIKit.h>
#import "SHInstagram.h"

// A paginating 3-column grid of posts. The loader fetches a page given a max_id (nil for the first page) and
// calls the completion with the posts and the next max_id. Tapping a thumbnail opens the post detail.
typedef SHHTTPTask *(^SHGridLoader)(NSString *maxId, SHFeedCompletion completion);

@interface SHGridViewController : UIViewController
- (instancetype)initWithTitle:(NSString *)title loader:(SHGridLoader)loader;
@property (nonatomic, copy) NSString *emptyMessage;   // shown when a successful load returns nothing
// An optional second list reachable from a bar button (Explore → Reels): a grid, or with secondaryFullScreen the
// full-screen player of short videos.
@property (nonatomic, copy) NSString *secondaryTitle;
@property (nonatomic, copy) SHGridLoader secondaryLoader;
@property (nonatomic) BOOL secondaryFullScreen;
@property (nonatomic, copy) void (^secondaryCachedLoader)(SHFeedCompletion completion);   // shown at once there
- (void)refresh;
@end
