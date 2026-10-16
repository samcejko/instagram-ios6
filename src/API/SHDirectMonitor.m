#import "SHDirectMonitor.h"
#import "SHInstagram.h"
#import "SHRealtime.h"
#import "SHSettings.h"
#import "SHModels.h"
#import "SHCommon.h"

NSString * const SHDirectUnreadDidChangeNotification = @"SHDirectUnreadDidChangeNotification";

@implementation SHDirectMonitor {
    NSMutableSet *_unread;            // thread ids
    NSMutableDictionary *_readUpTo;   // thread id -> the newest message read here (NSDate)
    NSMutableSet *_known;             // the threads of the last first page (a message elsewhere may be a request)
    CFAbsoluteTime _inboxAt;
    CFAbsoluteTime _requestedAt;      // a first page asked for
    BOOL _refreshPlanned;
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
        _known = [NSMutableSet set];
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(realtimeItem:) name:SHRealtimeDirectItemNotification object:nil];
        [nc addObserver:self selector:@selector(realtimeSeen:) name:SHRealtimeDirectSeenNotification object:nil];
        [nc addObserver:self selector:@selector(realtimeInboxChanged:) name:SHRealtimeInboxChangedNotification object:nil];
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

- (void)noteInboxRequested { _requestedAt = CFAbsoluteTimeGetCurrent(); }

- (void)noteInboxThreads:(NSArray *)threads
{
    _inboxAt = CFAbsoluteTimeGetCurrent();
    NSMutableSet *unread = [NSMutableSet set];
    [_known removeAllObjects];
    for (SHDirectThread *t in threads) {
        if (!t.threadId.length) continue;
        [_known addObject:t.threadId];
        if ([self threadIsUnread:t]) [unread addObject:t.threadId];
    }
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
    [_known removeAllObjects];
    _inboxAt = 0;
    _openThreadId = nil;
    [self setUnread:[NSSet set]];
}

#pragma mark - The live connection

// One first page soon, unless one is on its way or just came (the Direct tab may be asking for one itself).
- (void)refreshInboxSoon
{
    if (_refreshPlanned || CFAbsoluteTimeGetCurrent() - _requestedAt < 10) return;
    _refreshPlanned = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_refreshPlanned = NO;
        if (CFAbsoluteTimeGetCurrent() - self->_requestedAt < 10 || ![SHSettings isLoggedIn]) return;
        [SHInstagram directInboxWithCursor:nil completion:nil];
    });
}

// A message came: from me (here or on another device) the chat is read; from someone else it is unread unless it is
// the chat on screen. One of a chat this list does not know (perhaps a message request) is left to an inbox.
- (void)realtimeItem:(NSNotification *)note
{
    NSDictionary *info = note.userInfo;
    NSString *thread = info[SHRealtimeThreadKey];
    NSDictionary *item = info[SHRealtimeItemKey];
    if (![info[SHRealtimeOpKey] isEqualToString:@"add"] || !thread.length || !item) return;
    NSString *type = SHStr(item[@"item_type"]) ?: @"";
    if ([type isEqualToString:@"video_call_event"] || [type isEqualToString:@"action_log"]) return;   // (no unread for these)
    NSString *sender = SHStr(item[@"user_id"]) ?: @"";
    double ts = SHDbl(item[@"timestamp"]);
    if (ts > 1e14) ts /= 1e6;
    NSDate *when = ts > 0 ? [NSDate dateWithTimeIntervalSince1970:ts] : nil;
    if ([sender isEqualToString:[SHSettings userId] ?: @""]) { [self noteThreadRead:thread upTo:when]; return; }
    BOOL active = [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
    if (active && [thread isEqualToString:_openThreadId ?: @""]) return;   // (the chat marks it read)
    if (![_known containsObject:thread]) { [self refreshInboxSoon]; return; }
    if ([_unread containsObject:thread]) return;
    NSMutableSet *unread = [_unread mutableCopy];
    [unread addObject:thread];
    [self setUnread:unread];
}

// Read on another device (or the web): off the badge here too.
- (void)realtimeSeen:(NSNotification *)note
{
    NSDictionary *info = note.userInfo;
    if (![info[SHRealtimeUserKey] isEqualToString:[SHSettings userId] ?: @""]) return;
    [self noteThreadRead:info[SHRealtimeThreadKey] upTo:info[SHRealtimeDateKey]];
}

- (void)realtimeInboxChanged:(NSNotification *)note
{
    NSString *thread = note.userInfo[SHRealtimeThreadKey];
    NSString *op = note.userInfo[SHRealtimeOpKey];
    if ([op isEqualToString:@"remove"] && thread.length) {   // a chat deleted (or hidden)
        [_known removeObject:thread];
        if ([_unread containsObject:thread]) {
            NSMutableSet *unread = [_unread mutableCopy];
            [unread removeObject:thread];
            [self setUnread:unread];
        }
        return;
    }
    if ([op isEqualToString:@"add"] && thread.length && ![_known containsObject:thread]) [self refreshInboxSoon];
}

@end
