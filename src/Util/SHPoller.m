#import "SHPoller.h"
#import "SHRealtime.h"
#import "SHCommon.h"

NSString * const SHUserReturnedNotification = @"SHUserReturnedNotification";

static const NSTimeInterval SHPollSlowAfterIdle = 180;   // no touch for 3 minutes: at most once a minute
static const NSTimeInterval SHPollStopAfterIdle = 900;   // 15 minutes: nothing until the next touch
static const NSTimeInterval SHUserReturnGap     = 120;   // a touch after this long counts as coming back

static CFAbsoluteTime g_lastActivity = 0;

void SHNoteUserActivity(void)
{
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL returned = g_lastActivity > 0 && now - g_lastActivity > SHUserReturnGap;
    g_lastActivity = now;
    if (returned) [[NSNotificationCenter defaultCenter] postNotificationName:SHUserReturnedNotification object:nil];
}

NSTimeInterval SHSecondsSinceUserActivity(void)
{
    if (g_lastActivity <= 0) g_lastActivity = CFAbsoluteTimeGetCurrent();   // (counted from the start)
    return CFAbsoluteTimeGetCurrent() - g_lastActivity;
}

@implementation SHActivityWindow

- (void)sendEvent:(UIEvent *)event
{
    if (event.type == UIEventTypeTouches) SHNoteUserActivity();
    [super sendEvent:event];
}

@end

@implementation SHPoller {
    NSTimeInterval _min, _max, _interval;
    void (^_block)(void (^)(BOOL));
    BOOL _inFlight;
    CFAbsoluteTime _lastPoll;
    NSUInteger _generation;   // each wait scheduled replaces the one before (a stale one does nothing)
}

- (instancetype)initWithMinInterval:(NSTimeInterval)minInterval maxInterval:(NSTimeInterval)maxInterval
                              block:(void (^)(void (^)(BOOL)))block
{
    if ((self = [super init])) {
        _min = MAX(1, minInterval);
        _max = MAX(_min, maxInterval);
        _interval = _min;
        _block = [block copy];
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(appBecameActive) name:UIApplicationDidBecomeActiveNotification object:nil];
        [nc addObserver:self selector:@selector(appResigned) name:UIApplicationWillResignActiveNotification object:nil];
        [nc addObserver:self selector:@selector(userReturned) name:SHUserReturnedNotification object:nil];
        [nc addObserver:self selector:@selector(liveChanged) name:SHRealtimeStateDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)start { [self startAfter:-1]; }

- (void)startAfter:(NSTimeInterval)delay
{
    if (_running) return;
    _running = YES;
    _interval = _min;
    if (delay < 0) {
        NSTimeInterval since = CFAbsoluteTimeGetCurrent() - _lastPoll;
        NSTimeInterval wait = (_liveInterval > 0 && [SHRealtime shared].live) ? MAX(_min, _liveInterval) : _min;
        delay = since >= wait ? 0 : wait - since;
    }
    [self scheduleIn:delay];
}

- (void)stop
{
    _running = NO;
    _generation++;
}

- (void)noteFresh { _lastPoll = CFAbsoluteTimeGetCurrent(); }

- (void)speedUp
{
    _interval = _min;
    if (_liveInterval > 0 && [SHRealtime shared].live) return;   // (the live connection brings it)
    if (_running && !_inFlight) [self scheduleIn:_min];
}

- (void)scheduleIn:(NSTimeInterval)delay
{
    NSUInteger generation = ++_generation;
    __weak SHPoller *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0, delay) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SHPoller *poller = weakSelf;
        if (poller && poller->_generation == generation) [poller fire];
    });
}

- (NSTimeInterval)nextWait
{
    NSTimeInterval wait = _interval;
    if (SHSecondsSinceUserActivity() > SHPollSlowAfterIdle) wait = MAX(wait, 60);
    if (_liveInterval > 0 && [SHRealtime shared].live) wait = MAX(wait, _liveInterval);
    return wait;
}

// The connection went down: asking often again starts now, not after the long wait that was planned.
- (void)liveChanged
{
    if (_liveInterval <= 0 || !_running || [SHRealtime shared].live) return;
    [self speedUp];
}

- (void)fire
{
    if (!_running) return;
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;   // (on again when it is)
    if (_inFlight) {
        // an answer is still on its way (or it got lost: after a minute it no longer counts)
        if (CFAbsoluteTimeGetCurrent() - _lastPoll < 60) { [self scheduleIn:_min]; return; }
        _inFlight = NO;
    }
    if (SHSecondsSinceUserActivity() > SHPollStopAfterIdle) return;   // (on again with the next touch)
    _inFlight = YES;
    _lastPoll = CFAbsoluteTimeGetCurrent();
    NSUInteger generation = _generation;
    __weak SHPoller *weakSelf = self;
    _block(^(BOOL changed) {
        SHPoller *poller = weakSelf;
        if (!poller || !poller->_inFlight) return;
        poller->_inFlight = NO;
        poller->_lastPoll = CFAbsoluteTimeGetCurrent();
        poller->_interval = changed ? poller->_min : MIN(poller->_max, poller->_interval * 1.5);
        if (!poller->_running || poller->_generation != generation) return;   // stopped, or a newer wait runs
        [poller scheduleIn:[poller nextWait]];
    });
}

- (void)appBecameActive
{
    SHNoteUserActivity();   // (coming back to the app is using it)
    if (!_running) return;
    _interval = _min;
    NSTimeInterval since = CFAbsoluteTimeGetCurrent() - _lastPoll;
    [self scheduleIn:since >= _min ? 1 : _min - since];   // (a second for the Wi-Fi to come back after unlocking)
}

- (void)appResigned { _generation++; }   // nothing runs while the app is away

- (void)userReturned
{
    if (!_running || _inFlight) return;
    _interval = _min;
    [self scheduleIn:0];
}

@end
