#import "SHConnectionPool.h"
#import "SHTLSSocket.h"
#import "SHCommon.h"

static const NSTimeInterval SHIdleTimeout = 25;     // most servers drop idle connections after 5 to 60 s
static const NSUInteger SHMaxIdlePerKey = 6;
static const NSUInteger SHMaxIdleTotal = 24;

@interface SHPooledConnection : NSObject
@property (nonatomic, strong) SHTLSSocket *socket;
@property (nonatomic) NSTimeInterval lastUsed;
@end

@implementation SHPooledConnection
@end

@implementation SHConnectionPool {
    NSMutableDictionary *_idle;     // key -> NSMutableArray<SHPooledConnection>
    NSUInteger _count;
    NSUInteger _reuses;
}

+ (instancetype)shared
{
    static SHConnectionPool *pool;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pool = [[SHConnectionPool alloc] init]; });
    return pool;
}

- (instancetype)init
{
    self = [super init];
    if (self) _idle = [NSMutableDictionary dictionary];
    return self;
}

// Must be called with the lock held. Moves expired connections into `dead`.
- (void)pruneLocked:(NSMutableArray *)dead
{
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSMutableArray *emptyKeys = [NSMutableArray array];
    for (NSString *key in _idle) {
        NSMutableArray *list = _idle[key];
        for (NSInteger i = (NSInteger)list.count - 1; i >= 0; i--) {
            SHPooledConnection *c = list[(NSUInteger)i];
            if (now - c.lastUsed > SHIdleTimeout) {
                [dead addObject:c.socket];
                [list removeObjectAtIndex:(NSUInteger)i];
                _count--;
            }
        }
        if (!list.count) [emptyKeys addObject:key];
    }
    [_idle removeObjectsForKeys:emptyKeys];
}

- (SHTLSSocket *)checkoutSocketForKey:(NSString *)key
{
    if (!key) return nil;
    NSMutableArray *dead = [NSMutableArray array];
    SHTLSSocket *result = nil;
    @synchronized (self) {
        [self pruneLocked:dead];
        NSMutableArray *list = _idle[key];
        while (list.count && !result) {
            SHPooledConnection *c = [list lastObject];
            [list removeLastObject];
            _count--;
            if ([c.socket isLikelyAlive]) result = c.socket;
            else [dead addObject:c.socket];
        }
        if (result) _reuses++;
    }
    for (SHTLSSocket *s in dead) [s close];
    return result;
}

- (void)checkinSocket:(SHTLSSocket *)socket forKey:(NSString *)key
{
    if (!socket || !key) return;
    NSMutableArray *dead = [NSMutableArray array];
    @synchronized (self) {
        [self pruneLocked:dead];
        NSMutableArray *list = _idle[key];
        if (!list) {
            list = [NSMutableArray array];
            _idle[key] = list;
        }
        if (list.count >= SHMaxIdlePerKey || _count >= SHMaxIdleTotal) {
            [dead addObject:socket];
        } else {
            SHPooledConnection *c = [[SHPooledConnection alloc] init];
            c.socket = socket;
            c.lastUsed = [NSDate timeIntervalSinceReferenceDate];
            [list addObject:c];
            _count++;
        }
    }
    for (SHTLSSocket *s in dead) [s close];
}

- (void)drain
{
    NSMutableArray *dead = [NSMutableArray array];
    @synchronized (self) {
        for (NSString *key in _idle) {
            for (SHPooledConnection *c in _idle[key]) [dead addObject:c.socket];
        }
        [_idle removeAllObjects];
        _count = 0;
    }
    for (SHTLSSocket *s in dead) [s close];
    if (dead.count) SHLog(@"Connection pool drained (%lu closed)", (unsigned long)dead.count);
}

- (NSUInteger)idleCount
{
    @synchronized (self) { return _count; }
}

- (NSUInteger)reuseCount
{
    @synchronized (self) { return _reuses; }
}

@end
