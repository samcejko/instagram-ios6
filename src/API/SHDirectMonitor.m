#import "SHDirectMonitor.h"
#import "SHModels.h"
#import "SHCommon.h"

NSString * const SHDirectUnreadDidChangeNotification = @"SHDirectUnreadDidChangeNotification";

@implementation SHDirectMonitor {
    NSMutableSet *_unread;            // thread ids
    NSMutableDictionary *_readUpTo;   // thread id -> the newest message read here (NSDate)
    CFAbsoluteTime _inboxAt;
}

+ (instancetype)shared
{
    static SHDirectMonitor *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[SHDirectMonitor alloc] init]; });
    return s;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _unread = [NSMutableSet set];
        _readUpTo = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSUInteger)unreadCount { return _unread.count; }

- (NSTimeInterval)secondsSinceInbox { return _inboxAt > 0 ? CFAbsoluteTimeGetCurrent() - _inboxAt : 1e9; }

- (BOOL)threadIsUnread:(SHDirectThread *)thread
{
    if (!thread.unread) return NO;
    NSDate *read = _readUpTo[thread.threadId ?: @""];
    // (read here up to its newest message: Instagram's answer was older than the reading)
    return !(read && thread.lastActivity && [thread.lastActivity compare:read] != NSOrderedDescending);
}

- (void)setUnread:(NSSet *)unread
{
    if ([unread isEqualToSet:_unread]) return;
    NSUInteger before = _unread.count;
    [_unread setSet:unread];
    if (before != _unread.count) SHLog(@"DIRECT unread=%lu", (unsigned long)_unread.count);
    [[NSNotificationCenter defaultCenter] postNotificationName:SHDirectUnreadDidChangeNotification object:self];
}

- (void)noteInboxThreads:(NSArray *)threads
{
    _inboxAt = CFAbsoluteTimeGetCurrent();
    NSMutableSet *unread = [NSMutableSet set];
    for (SHDirectThread *t in threads) if (t.threadId.length && [self threadIsUnread:t]) [unread addObject:t.threadId];
    [self setUnread:unread];
}

- (void)noteThreadRead:(NSString *)threadId upTo:(NSDate *)newest
{
    if (!threadId.length) return;
    if (newest) {
        NSDate *before = _readUpTo[threadId];
        if (!before || [newest compare:before] == NSOrderedDescending) _readUpTo[threadId] = newest;
    }
    if (![_unread containsObject:threadId]) return;
    NSMutableSet *unread = [_unread mutableCopy];
    [unread removeObject:threadId];
    [self setUnread:unread];
}

- (void)reset
{
    [_readUpTo removeAllObjects];
    _inboxAt = 0;
    [self setUnread:[NSSet set]];
}

@end
