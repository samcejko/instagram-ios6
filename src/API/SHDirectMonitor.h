#import <Foundation/Foundation.h>

@class SHDirectThread;

// How many conversations have something unread: the badge of the Direct tab. Counted from every first page of the
// inbox loaded (by the Direct tab, or now and then by the tab bar while the app is used elsewhere); a chat read here
// is taken off at once, also when an inbox asked for before the reading still calls it unread. While the live
// connection is up its messages count at once (a chat never seen before brings one inbox to check).
extern NSString * const SHDirectUnreadDidChangeNotification;

@interface SHDirectMonitor : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) NSUInteger unreadCount;
@property (nonatomic, readonly) NSTimeInterval secondsSinceInbox;    // since an inbox was last loaded
@property (nonatomic, copy) NSString *openThreadId;                  // the chat on screen: what comes there is read
- (void)noteInboxRequested;                                          // a first page is on its way
- (void)noteInboxThreads:(NSArray *)threads;                         // SHDirectThread: the inbox's first page
- (void)noteThreadRead:(NSString *)threadId upTo:(NSDate *)newest;   // the newest message read in a chat
- (BOOL)threadIsUnread:(SHDirectThread *)thread;
- (void)reset;                                                       // logged out
@end
