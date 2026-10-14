#import <UIKit/UIKit.h>

// Loader for a paginated list of SHUser. Pass nil maxId for the first page; query is a filter (may be nil).
typedef void (^SHUserListResult)(NSArray *users, NSString *nextMaxId, NSError *error);
typedef id (^SHUserListLoader)(NSString *maxId, NSString *query, SHUserListResult result);

// A list of accounts (followers, following, likers, ...). Tapping a row opens that profile.
@interface SHUserListViewController : UIViewController
- (instancetype)initWithTitle:(NSString *)title loader:(SHUserListLoader)loader searchable:(BOOL)searchable;
- (instancetype)initWithTitle:(NSString *)title users:(NSArray *)users;   // a fixed list (e.g. likers)
@end
