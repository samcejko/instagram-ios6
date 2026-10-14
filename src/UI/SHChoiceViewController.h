#import <UIKit/UIKit.h>

// A list of options with a checkmark on the chosen one
@interface SHChoiceViewController : UITableViewController
@property (nonatomic, strong) NSArray *titles;
@property (nonatomic, strong) NSArray *subtitles;       // optional, same count
@property (nonatomic) NSInteger selectedIndex;
@property (nonatomic, copy) void (^completion)(NSInteger index);
@end
