#import "SHRealtime.h"
#import "SHTLSSocket.h"
#import "SHInstagram.h"
#import "SHSettings.h"
#import "SHUtils.h"
#import "SHCommon.h"

#include <zlib.h>
#include <poll.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>

NSString * const SHRealtimeStateDidChangeNotification = @"SHRealtimeStateDidChangeNotification";
NSString * const SHRealtimeDirectItemNotification     = @"SHRealtimeDirectItemNotification";
NSString * const SHRealtimeDirectSeenNotification     = @"SHRealtimeDirectSeenNotification";
NSString * const SHRealtimeDirectTypingNotification   = @"SHRealtimeDirectTypingNotification";
NSString * const SHRealtimeInboxChangedNotification   = @"SHRealtimeInboxChangedNotification";

NSString * const SHRealtimeThreadKey = @"thread";
NSString * const SHRealtimeOpKey     = @"op";
NSString * const SHRealtimeItemIdKey = @"itemId";
NSString * const SHRealtimeItemKey   = @"item";
NSString * const SHRealtimeUserKey   = @"user";
NSString * const SHRealtimeDateKey   = @"date";
NSString * const SHRealtimeTypingKey = @"typing";
NSString * const SHRealtimeTTLKey    = @"ttl";

static NSString * const SHRTHost = @"edge-mqtt.facebook.com";
static const int SHRTPort = 443;
static const int SHRTKeepAlive = 60;                    // seconds, as told to the server in CONNECT
static const NSTimeInterval SHRTPingAfter = 30;         // a PINGREQ after this long without sending anything,
static const NSTimeInterval SHRTPongWait = 20;          // and the connection is dead when no PINGRESP came by then
static const NSTimeInterval SHRTConnackWait = 20;
static const NSTimeInterval SHRTIrisWait = 20;          // for the answer to the message sync subscription
static const NSTimeInterval SHRTRefusedPause = 1800;    // after Instagram refused the session twice
static const NSUInteger SHRTMaxPacket = 8 * 1024 * 1024;

// The topics, by the numbers that travel instead of their names (notes/realtime-mqtt.md)
static NSString * const SHRTTopicPubsub       = @"88";    // /pubsub (typing)
static NSString * const SHRTTopicIrisSub      = @"134";   // /ig_sub_iris
static NSString * const SHRTTopicIrisAnswer   = @"135";   // /ig_sub_iris_response
static NSString * const SHRTTopicMessageSync  = @"146";   // /ig_message_sync
static NSString * const SHRTTopicRealtimeSub  = @"149";   // /ig_realtime_sub (typing)
static NSString * const SHRTTopicReconnect    = @"34";    // /pp: the server wants a new connection

static NSString * const SHRTTypingQueryId = @"17867973967082385";   // the GraphQL subscription "direct typing"
static NSString * const SHRTAuthFormKey = @"SHRealtimeAuthForm";      // which password form Instagram accepted last

// Debug builds say what the connection does (the "debug" file in Documents, read once). Never the session.
static BOOL SHRTDebug(void)
{
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        on = [[NSFileManager defaultManager] fileExistsAtPath:[[SHUtils documentsPath] stringByAppendingPathComponent:@"debug"]];
    });
    return on;
}

#define RTLog(fmt, ...) do { if (SHRTDebug()) SHLog(@"RT " fmt, ##__VA_ARGS__); } while (0)

static long long SHRTNowMs(void) { return (long long)([[NSDate date] timeIntervalSince1970] * 1000.0); }

#pragma mark - zlib

static NSData *SHRTDeflate(NSData *data)
{
    uLongf size = compressBound((uLong)data.length);
    NSMutableData *out = [NSMutableData dataWithLength:size];
    if (compress2((Bytef *)out.mutableBytes, &size, (const Bytef *)data.bytes, (uLong)data.length, 9) != Z_OK) return nil;
    out.length = size;
    return out;
}

// A zlib (or gzip) stream inflated; nil when the bytes are not one.
static NSData *SHRTInflate(NSData *data)
{
    if (data.length < 2) return nil;
    const uint8_t *b = (const uint8_t *)data.bytes;
    BOOL zlibHeader = (b[0] & 0x0F) == 8 && (((unsigned)b[0] << 8) | b[1]) % 31 == 0;
    BOOL gzip = b[0] == 0x1F && b[1] == 0x8B;
    if (!zlibHeader && !gzip) return nil;
    z_stream s;
    memset(&s, 0, sizeof(s));
    if (inflateInit2(&s, 15 + 32) != Z_OK) return nil;
    s.next_in = (Bytef *)data.bytes;
    s.avail_in = (uInt)data.length;
    NSMutableData *out = [NSMutableData dataWithLength:MAX(data.length * 4, (NSUInteger)4096)];
    int ret;
    do {
        if (s.total_out >= out.length) {
            if (out.length >= 32 * 1024 * 1024) { inflateEnd(&s); return nil; }
            out.length = out.length * 2;
        }
        s.next_out = (Bytef *)out.mutableBytes + s.total_out;
        s.avail_out = (uInt)(out.length - s.total_out);
        ret = inflate(&s, Z_NO_FLUSH);
    } while (ret == Z_OK);
    NSUInteger produced = (NSUInteger)s.total_out;
    inflateEnd(&s);
    if (ret != Z_STREAM_END) return nil;
    out.length = produced;
    return out;
}

#pragma mark - Thrift (compact protocol)

enum {
    SHTCBoolTrue = 1, SHTCBoolFalse = 2, SHTCByte = 3, SHTCI16 = 4, SHTCI32 = 5, SHTCI64 = 6,
    SHTCDouble = 7, SHTCBinary = 8, SHTCList = 9, SHTCSet = 10, SHTCMap = 11, SHTCStruct = 12,
};

// Writes the few shapes the CONNECT payload needs, field by field (short field headers where the gap allows).
@interface SHThriftWriter : NSObject
@property (nonatomic, readonly) NSMutableData *data;
- (void)binary:(id)value field:(int16_t)fid;        // NSString (UTF-8) or NSData
- (void)i64:(int64_t)value field:(int16_t)fid;
- (void)i32:(int32_t)value field:(int16_t)fid;
- (void)byte:(int8_t)value field:(int16_t)fid;
- (void)boolean:(BOOL)value field:(int16_t)fid;
- (void)i32List:(NSArray *)numbers field:(int16_t)fid;
- (void)stringMap:(NSDictionary *)map field:(int16_t)fid;
- (void)beginStruct:(int16_t)fid;
- (void)endStruct;
- (void)stop;                                        // the end of the outermost struct
@end

@implementation SHThriftWriter {
    int16_t _last[8];   // the previous field id, per open struct
    int _depth;
}

- (instancetype)init
{
    if ((self = [super init])) _data = [NSMutableData data];
    return self;
}

- (void)put:(uint8_t)b { [_data appendBytes:&b length:1]; }

- (void)varint:(uint64_t)v
{
    uint8_t buf[10];
    int n = 0;
    while (v >= 0x80) { buf[n++] = (uint8_t)((v & 0x7F) | 0x80); v >>= 7; }
    buf[n++] = (uint8_t)v;
    [_data appendBytes:buf length:(NSUInteger)n];
}

static uint32_t SHTZigzag32(int32_t v) { return ((uint32_t)v << 1) ^ (uint32_t)(v >> 31); }
static uint64_t SHTZigzag64(int64_t v) { return ((uint64_t)v << 1) ^ (uint64_t)(v >> 63); }

- (void)header:(uint8_t)type field:(int16_t)fid
{
    int delta = fid - _last[_depth];
    if (delta > 0 && delta <= 15) {
        [self put:(uint8_t)((delta << 4) | type)];
    } else {
        [self put:type];
        [self varint:SHTZigzag32(fid)];
    }
    _last[_depth] = fid;
}

- (void)raw:(id)value
{
    NSData *d = [value isKindOfClass:[NSData class]] ? value : [[value description] dataUsingEncoding:NSUTF8StringEncoding];
    [self varint:d.length];
    if (d.length) [_data appendData:d];
}

- (void)binary:(id)value field:(int16_t)fid { [self header:SHTCBinary field:fid]; [self raw:value ?: @""]; }
- (void)i64:(int64_t)value field:(int16_t)fid { [self header:SHTCI64 field:fid]; [self varint:SHTZigzag64(value)]; }
- (void)i32:(int32_t)value field:(int16_t)fid { [self header:SHTCI32 field:fid]; [self varint:SHTZigzag32(value)]; }
- (void)byte:(int8_t)value field:(int16_t)fid { [self header:SHTCByte field:fid]; [self put:(uint8_t)value]; }
- (void)boolean:(BOOL)value field:(int16_t)fid { [self header:value ? SHTCBoolTrue : SHTCBoolFalse field:fid]; }

- (void)i32List:(NSArray *)numbers field:(int16_t)fid
{
    [self header:SHTCList field:fid];
    NSUInteger n = numbers.count;
    if (n < 15) [self put:(uint8_t)((n << 4) | SHTCI32)];
    else { [self put:0xF0 | SHTCI32]; [self varint:n]; }
    for (NSNumber *num in numbers) [self varint:SHTZigzag32([num intValue])];
}

- (void)stringMap:(NSDictionary *)map field:(int16_t)fid
{
    [self header:SHTCMap field:fid];
    if (!map.count) { [self put:0]; return; }
    [self varint:map.count];
    [self put:(SHTCBinary << 4) | SHTCBinary];
    for (NSString *key in map) {
        [self raw:key];
        [self raw:map[key]];
    }
}

- (void)beginStruct:(int16_t)fid
{
    [self header:SHTCStruct field:fid];
    if (_depth < 7) _depth++;
    _last[_depth] = 0;
}

- (void)endStruct
{
    [self put:0];
    if (_depth > 0) _depth--;
}

- (void)stop { [self put:0]; }

@end

static BOOL SHTReadVarint(const uint8_t *p, NSUInteger len, NSUInteger *off, uint64_t *out)
{
    uint64_t v = 0;
    for (int shift = 0; *off < len && shift < 64; shift += 7) {
        uint8_t b = p[(*off)++];
        v |= (uint64_t)(b & 0x7F) << shift;
        if (!(b & 0x80)) { *out = v; return YES; }
    }
    return NO;
}

static int64_t SHTUnzigzag(uint64_t z) { return (int64_t)(z >> 1) ^ -(int64_t)(z & 1); }

static BOOL SHTSkip(const uint8_t *p, NSUInteger len, NSUInteger *off, uint8_t type, int depth);

// One element of a list or map (where a bool takes a byte of its own).
static BOOL SHTSkipElement(const uint8_t *p, NSUInteger len, NSUInteger *off, uint8_t type, int depth)
{
    if (type == SHTCBoolTrue || type == SHTCBoolFalse) {
        if (*off >= len) return NO;
        (*off)++;
        return YES;
    }
    return SHTSkip(p, len, off, type, depth);
}

static BOOL SHTSkip(const uint8_t *p, NSUInteger len, NSUInteger *off, uint8_t type, int depth)
{
    if (depth > 16) return NO;
    uint64_t v = 0;
    switch (type) {
        case SHTCBoolTrue: case SHTCBoolFalse: return YES;   // (a field's value is in its header)
        case SHTCByte: if (*off >= len) return NO; (*off)++; return YES;
        case SHTCI16: case SHTCI32: case SHTCI64: return SHTReadVarint(p, len, off, &v);
        case SHTCDouble: if (len - *off < 8) return NO; *off += 8; return YES;
        case SHTCBinary:
            if (!SHTReadVarint(p, len, off, &v) || v > len - *off) return NO;
            *off += (NSUInteger)v;
            return YES;
        case SHTCList: case SHTCSet: {
            if (*off >= len) return NO;
            uint8_t h = p[(*off)++];
            uint64_t n = h >> 4;
            if (n == 15 && !SHTReadVarint(p, len, off, &n)) return NO;
            for (uint64_t i = 0; i < n; i++) if (!SHTSkipElement(p, len, off, h & 0x0F, depth + 1)) return NO;
            return YES;
        }
        case SHTCMap: {
            uint64_t n = 0;
            if (!SHTReadVarint(p, len, off, &n)) return NO;
            if (n == 0) return YES;
            if (*off >= len) return NO;
            uint8_t kv = p[(*off)++];
            for (uint64_t i = 0; i < n; i++) {
                if (!SHTSkipElement(p, len, off, kv >> 4, depth + 1) || !SHTSkipElement(p, len, off, kv & 0x0F, depth + 1)) return NO;
            }
            return YES;
        }
        case SHTCStruct:
            for (;;) {
                if (*off >= len) return NO;
                uint8_t h = p[(*off)++];
                if (h == 0) return YES;
                if (!(h >> 4) && !SHTReadVarint(p, len, off, &v)) return NO;   // (a long field header: the id follows)
                if (!SHTSkip(p, len, off, h & 0x0F, depth + 1)) return NO;
            }
        default:
            return NO;
    }
}

// The envelope of /pubsub and /ig_realtime_sub: {1: topic (a name, or a number), 2: payload}.
static BOOL SHTReadEnvelope(NSData *data, NSString **topic, NSData **payload)
{
    const uint8_t *p = (const uint8_t *)data.bytes;
    NSUInteger len = data.length, off = 0;
    int64_t fid = 0;
    while (off < len) {
        uint8_t h = p[off++];
        if (h == 0) break;
        uint8_t type = h & 0x0F;
        if (h >> 4) {
            fid += h >> 4;
        } else {
            uint64_t z = 0;
            if (!SHTReadVarint(p, len, &off, &z)) return NO;
            fid = SHTUnzigzag(z);
        }
        if (type == SHTCBinary && (fid == 1 || fid == 2)) {
            uint64_t n = 0;
            if (!SHTReadVarint(p, len, &off, &n) || n > len - off) return NO;
            NSData *d = [data subdataWithRange:NSMakeRange(off, (NSUInteger)n)];
            off += (NSUInteger)n;
            if (fid == 1) *topic = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            else *payload = d;
        } else if (fid == 1 && (type == SHTCI16 || type == SHTCI32 || type == SHTCI64)) {
            uint64_t z = 0;
            if (!SHTReadVarint(p, len, &off, &z)) return NO;
            *topic = [NSString stringWithFormat:@"%lld", SHTUnzigzag(z)];
        } else if (!SHTSkip(p, len, &off, type, 0)) {
            return NO;
        }
    }
    return *payload != nil;
}

#pragma mark - MQTT packets

static void SHRTAppendLength(NSMutableData *d, NSUInteger len)
{
    do {
        uint8_t b = (uint8_t)(len % 128);
        len /= 128;
        if (len) b |= 0x80;
        [d appendBytes:&b length:1];
    } while (len);
}

static NSData *SHRTPacket(uint8_t header, NSData *body)
{
    NSMutableData *d = [NSMutableData dataWithCapacity:body.length + 5];
    [d appendBytes:&header length:1];
    SHRTAppendLength(d, body.length);
    if (body.length) [d appendData:body];
    return d;
}

// CONNECT the MQTToT way: the protocol name "MQTToT", level 3, the flags of a username, a password and a clean
// session, the keep-alive, and then the compressed Thrift payload as it is (no length in front, no other fields).
static NSData *SHRTConnectPacket(NSData *payload)
{
    const uint8_t head[] = { 0x00, 0x06, 'M', 'Q', 'T', 'T', 'o', 'T', 3, 0xC2,
                             (uint8_t)((SHRTKeepAlive >> 8) & 0xFF), (uint8_t)(SHRTKeepAlive & 0xFF) };
    NSMutableData *b = [NSMutableData dataWithBytes:head length:sizeof(head)];
    [b appendData:payload];
    return SHRTPacket(0x10, b);
}

static NSData *SHRTPublishPacket(NSString *topic, NSData *payload, uint16_t msgId)
{
    NSData *t = [topic dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *b = [NSMutableData dataWithCapacity:t.length + payload.length + 4];
    uint8_t tl[2] = { (uint8_t)(t.length >> 8), (uint8_t)(t.length & 0xFF) };
    [b appendBytes:tl length:2];
    [b appendData:t];
    uint8_t mid[2] = { (uint8_t)(msgId >> 8), (uint8_t)(msgId & 0xFF) };
    [b appendBytes:mid length:2];
    [b appendData:payload];
    return SHRTPacket(0x32, b);   // PUBLISH, QoS 1
}

static NSData *SHRTAckPacket(uint8_t header, uint16_t msgId)
{
    uint8_t p[4] = { header, 2, (uint8_t)(msgId >> 8), (uint8_t)(msgId & 0xFF) };
    return [NSData dataWithBytes:p length:4];
}

#pragma mark - What arrives

// A time as Instagram sends it (seconds, milliseconds or microseconds, number or string) as a date.
static NSDate *SHRTDate(id value)
{
    double t = SHDbl(value);
    if (t > 1e17) t /= 1e9;
    else if (t > 1e14) t /= 1e6;
    else if (t > 1e11) t /= 1e3;
    return t > 0 ? [NSDate dateWithTimeIntervalSince1970:t] : nil;
}

// A patch's value: a JSON object written into a string (an item id on its own for some removals).
static id SHRTValue(id value)
{
    if ([value isKindOfClass:[NSDictionary class]] || [value isKindOfClass:[NSArray class]]) return value;
    NSString *s = SHStr(value);
    if (!s.length) return nil;
    unichar c = [s characterAtIndex:0];
    if (c == '{' || c == '[') return [SHUtils JSONObjectFromData:[s dataUsingEncoding:NSUTF8StringEncoding]] ?: s;
    return s;
}

// One patch of the message sync ({"op", "path", "value"}) as an event for the main thread (nil: nothing for us):
//   item    /direct_v2/threads/<t>/items/<i>                  (a reaction below an item only changes the chat)
//   seen    /direct_v2/threads/<t>/participants/<u>/has_seen
//   typing  /direct_v2/threads/<t>/activity_indicator_id/<x>
//   thread  /direct_v2/inbox/threads/<t>, anything else under /direct_v2/threads/<t>
//   inbox   anything else under /direct_v2/inbox
static NSDictionary *SHRTPatchEvent(NSDictionary *patch)
{
    NSString *op = [SHStr(patch[@"op"]) lowercaseString] ?: @"";
    NSString *path = SHStr(patch[@"path"]) ?: @"";
    NSArray *parts = [path componentsSeparatedByString:@"/"];   // "", "direct_v2", …
    if (parts.count < 3 || ![parts[1] isEqualToString:@"direct_v2"]) return @{ @"kind": @"other", @"path": path };
    if ([parts[2] isEqualToString:@"threads"] && parts.count >= 4) {
        NSString *thread = parts[3];
        NSArray *rest = parts.count > 4 ? [parts subarrayWithRange:NSMakeRange(4, parts.count - 4)] : @[];
        if (rest.count == 2 && [rest[0] isEqualToString:@"items"]) {
            NSMutableDictionary *e = [@{ @"kind": @"item", @"thread": thread, @"item": rest[1], @"op": op } mutableCopy];
            NSDictionary *json = SHDict(SHRTValue(patch[@"value"]));
            if (json && ![op isEqualToString:@"remove"]) e[@"json"] = json;
            return e;
        }
        if (rest.count >= 3 && [rest[0] isEqualToString:@"participants"] && [rest[2] isEqualToString:@"has_seen"]) {
            NSMutableDictionary *e = [@{ @"kind": @"seen", @"thread": thread, @"user": rest[1] } mutableCopy];
            NSDictionary *v = SHDict(SHRTValue(patch[@"value"]));
            if (SHStr(v[@"item_id"]).length) e[@"item"] = SHStr(v[@"item_id"]);
            NSDate *date = SHRTDate(v[@"timestamp"]);
            if (date) e[@"date"] = date;
            return e;
        }
        if (rest.count >= 1 && [rest[0] isEqualToString:@"activity_indicator_id"]) {
            NSDictionary *v = SHDict(SHRTValue(patch[@"value"]));
            NSString *sender = SHStr(v[@"sender_id"]);
            if (!sender.length) return nil;
            NSInteger status = [op isEqualToString:@"remove"] ? 0 : SHInt(v[@"activity_status"]);
            double ttl = SHDbl(v[@"ttl"]);
            return @{ @"kind": @"typing", @"thread": thread, @"user": sender, @"status": @(status),
                      @"ttl": @(ttl > 0 ? MAX(1.0, ttl / 1000.0) : 12.0) };
        }
        return @{ @"kind": @"thread", @"thread": thread, @"op": op, @"path": path };
    }
    if ([parts[2] isEqualToString:@"inbox"]) {
        if (parts.count >= 5 && [parts[3] isEqualToString:@"threads"]) return @{ @"kind": @"thread", @"thread": parts[4], @"op": op, @"path": path };
        return @{ @"kind": @"inbox", @"op": op, @"path": path };
    }
    return @{ @"kind": @"other", @"path": path };
}

// One PUBLISH of the server as events for the main thread (worked out on the connection's own thread).
static NSArray *SHRTDecode(NSString *topic, NSData *payload)
{
    NSMutableArray *events = [NSMutableArray array];
    if ([topic isEqualToString:SHRTTopicMessageSync]) {
        id json = [SHUtils JSONObjectFromData:payload];
        NSArray *batches = SHArr(json) ?: (SHDict(json) ? @[ json ] : @[]);
        for (id b in batches) {
            NSDictionary *batch = SHDict(b);
            for (id p in SHArr(batch[@"data"])) {
                NSDictionary *e = SHDict(p) ? SHRTPatchEvent(p) : nil;
                if (e) [events addObject:e];
            }
            long long seq = [SHStr(batch[@"seq_id"]) longLongValue];
            if (seq > 0) [events addObject:@{ @"kind": @"seq", @"seq": @(seq) }];
        }
    } else if ([topic isEqualToString:SHRTTopicIrisAnswer]) {
        NSDictionary *json = SHDict([SHUtils JSONObjectFromData:payload]);
        if (json) [events addObject:@{ @"kind": @"iris", @"json": json }];
    } else if ([topic isEqualToString:SHRTTopicPubsub] || [topic isEqualToString:SHRTTopicRealtimeSub]) {
        // Thrift around JSON; only typing is taken from here (messages come by the message sync)
        NSString *inner = nil;
        NSData *body = nil;
        id json = SHTReadEnvelope(payload, &inner, &body) ? [SHUtils JSONObjectFromData:body] : nil;
        for (id p in SHArr(SHDict(json)[@"data"])) {
            NSDictionary *e = SHDict(p) ? SHRTPatchEvent(p) : nil;
            if ([e[@"kind"] isEqualToString:@"typing"]) [events addObject:e];
        }
        if (!events.count) [events addObject:@{ @"kind": @"other", @"path": inner ?: (json ? @"json" : @"?") }];
    } else if ([topic isEqualToString:SHRTTopicReconnect]) {
        [events addObject:@{ @"kind": @"reconnect" }];
    } else {
        [events addObject:@{ @"kind": @"other", @"path": @"" }];
    }
    return events;
}

#pragma mark - The connection (its own thread)

@class SHRealtimeConnection;

@protocol SHRealtimeConnectionDelegate <NSObject>
// (all on the main thread)
- (void)realtimeConnection:(SHRealtimeConnection *)connection connackCode:(int)code;
- (void)realtimeConnection:(SHRealtimeConnection *)connection events:(NSArray *)events topic:(NSString *)topic bytes:(NSUInteger)bytes;
- (void)realtimeConnection:(SHRealtimeConnection *)connection acked:(uint16_t)msgId;
// stage: 0 = before CONNECT went out, 1 = waiting for CONNACK, 2 = was connected. serverClosed: the server hung up.
- (void)realtimeConnection:(SHRealtimeConnection *)connection closedWithError:(NSError *)error stage:(int)stage serverClosed:(BOOL)serverClosed;
@end

// One TLS connection with its own thread: CONNECT, then reading and answering what comes (PUBACK, PINGRESP), the
// keep-alive, and what the main thread queues. Every socket call happens on that thread; the main thread only queues
// packets, wakes it through a pipe and, to tear it down, cancels the socket.
@interface SHRealtimeConnection : NSObject
@property (nonatomic, weak) id<SHRealtimeConnectionDelegate> delegate;
- (instancetype)initWithConnectPacket:(NSData *)packet verify:(BOOL)verify;
- (void)open;
- (void)send:(NSData *)packet;
- (void)close:(BOOL)graceful;   // graceful: DISCONNECT first; the delegate hears nothing more that matters
@end

@implementation SHRealtimeConnection {
    NSData *_connectPacket;
    BOOL _verify;
    NSMutableArray *_outgoing;
    int _wake[2];
    volatile BOOL _closing;
    volatile BOOL _graceful;
    SHTLSSocket *_socket;            // (guarded by @synchronized (self): the main thread may cancel it)
    int _stage;
    BOOL _eof;
    CFAbsoluteTime _lastWrite, _pingSentAt, _connectSentAt;
}

- (instancetype)initWithConnectPacket:(NSData *)packet verify:(BOOL)verify
{
    if ((self = [super init])) {
        _connectPacket = packet;
        _verify = verify;
        _outgoing = [NSMutableArray array];
        if (pipe(_wake) == 0) {
            fcntl(_wake[0], F_SETFL, fcntl(_wake[0], F_GETFL, 0) | O_NONBLOCK);
            fcntl(_wake[1], F_SETFL, fcntl(_wake[1], F_GETFL, 0) | O_NONBLOCK);
        } else {
            _wake[0] = _wake[1] = -1;
        }
    }
    return self;
}

- (void)dealloc
{
    if (_wake[0] >= 0) close(_wake[0]);
    if (_wake[1] >= 0) close(_wake[1]);
}

- (void)open
{
    NSThread *thread = [[NSThread alloc] initWithTarget:self selector:@selector(threadMain) object:nil];
    thread.name = @"SHRealtime";
    [thread start];
}

- (void)wake
{
    if (_wake[1] < 0) return;
    char c = 1;
    (void)write(_wake[1], &c, 1);
}

- (void)send:(NSData *)packet
{
    if (!packet.length || _closing) return;
    @synchronized (_outgoing) { [_outgoing addObject:packet]; }
    [self wake];
}

- (void)close:(BOOL)graceful
{
    if (_closing) return;
    _graceful = graceful;
    _closing = YES;
    [self wake];
    if (!graceful) {
        @synchronized (self) { [_socket cancel]; }
        return;
    }
    // a thread stuck in the handshake or a read does not see the pipe: cut it after a moment
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @synchronized (self) { [self->_socket cancel]; }
    });
}

- (void)threadMain
{
    @autoreleasepool {
        NSError *error = nil;
        SHTLSSocket *sock = [[SHTLSSocket alloc] init];
        @synchronized (self) { _socket = sock; }
        BOOL ok = !_closing && [sock connectToHost:SHRTHost port:SHRTPort verify:_verify connectTimeoutMs:15000 readTimeoutMs:30000 error:&error];
        if (ok && !_closing) {
            ok = [sock writeData:_connectPacket error:&error];
            _connectSentAt = _lastWrite = CFAbsoluteTimeGetCurrent();
            if (ok) _stage = 1;
        }
        if (ok && !_closing) [self pump:sock error:&error];
        if (_closing && _graceful && _stage == 2 && sock.isConnected) {
            static const uint8_t bye[2] = { 0xE0, 0x00 };   // DISCONNECT
            [sock writeData:[NSData dataWithBytes:bye length:2] error:NULL];
        }
        [sock close];
        @synchronized (self) { _socket = nil; }
        NSError *reported = _closing ? nil : (error ?: SHMakeError(SHErrorConnectionLost, @"The live connection was closed."));
        int stage = _stage;
        BOOL eof = _eof;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate realtimeConnection:self closedWithError:reported stage:stage serverClosed:eof];
        });
    }
}

// Reads and answers until the connection ends or is closed.
- (void)pump:(SHTLSSocket *)sock error:(NSError **)errorOut
{
    NSError *err = nil;
    NSMutableData *input = [NSMutableData data];
    const NSUInteger chunk = 16384;
    uint8_t *buf = (uint8_t *)malloc(chunk);
    if (!buf) return;
    BOOL failed = NO;
    while (!_closing && !failed) {
        @autoreleasepool {
            // what the main thread queued
            NSArray *queued = nil;
            @synchronized (_outgoing) {
                queued = [_outgoing copy];
                [_outgoing removeAllObjects];
            }
            for (NSData *packet in queued) {
                if (![sock writeData:packet error:&err]) { failed = YES; break; }
                _lastWrite = CFAbsoluteTimeGetCurrent();
            }
            if (failed) break;

            // the keep-alive, and the patience with the server's answers
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (_stage == 1 && now - _connectSentAt > SHRTConnackWait) {
                err = SHMakeError(SHErrorTimeout, @"No CONNACK.");
                failed = YES;
                break;
            }
            if (_pingSentAt > 0 && now - _pingSentAt > SHRTPongWait) {
                err = SHMakeError(SHErrorTimeout, @"No PINGRESP.");
                failed = YES;
                break;
            }
            if (_stage == 2 && _pingSentAt == 0 && now - _lastWrite >= SHRTPingAfter) {
                static const uint8_t ping[2] = { 0xC0, 0x00 };
                if (![sock writeData:[NSData dataWithBytes:ping length:2] error:&err]) { failed = YES; break; }
                _pingSentAt = _lastWrite = now;
            }

            // wait for bytes, the pipe or the next timer (bytes the TLS layer already holds are read at once)
            if (![sock hasBufferedData]) {
                NSTimeInterval wait = 5;
                if (_stage == 1) wait = MIN(wait, _connectSentAt + SHRTConnackWait - now);
                if (_pingSentAt > 0) wait = MIN(wait, _pingSentAt + SHRTPongWait - now);
                else if (_stage == 2) wait = MIN(wait, _lastWrite + SHRTPingAfter - now);
                int ms = (int)MAX(50.0, wait * 1000.0);
                struct pollfd pfd[2];
                memset(pfd, 0, sizeof(pfd));
                pfd[0].fd = sock.fileDescriptor;
                pfd[0].events = POLLIN;
                pfd[1].fd = _wake[0];
                pfd[1].events = POLLIN;
                nfds_t count = _wake[0] >= 0 ? 2 : 1;
                if (count == 1) ms = MIN(ms, 250);
                int pr = poll(pfd, count, ms);
                if (pr < 0) {
                    if (errno == EINTR) continue;
                    err = SHMakeError(SHErrorConnectionLost, [NSString stringWithFormat:@"poll: %s", strerror(errno)]);
                    failed = YES;
                    break;
                }
                if (count == 2 && (pfd[1].revents & POLLIN)) {
                    char drain[64];
                    while (read(_wake[0], drain, sizeof(drain)) > 0) {}
                }
                if (!(pfd[0].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            }

            NSInteger n = [sock readIntoBuffer:buf maxLength:chunk error:&err];
            if (n <= 0) {
                if (n == 0) _eof = YES;
                failed = YES;
                break;
            }
            [input appendBytes:buf length:(NSUInteger)n];
            if (![self handleInput:input socket:sock error:&err]) { failed = YES; break; }
        }
    }
    free(buf);
    if (errorOut) *errorOut = err;
}

// Takes every whole packet off the front of `input`.
- (BOOL)handleInput:(NSMutableData *)input socket:(SHTLSSocket *)sock error:(NSError **)error
{
    const uint8_t *p = (const uint8_t *)input.bytes;
    NSUInteger len = input.length, off = 0;
    BOOL ok = YES;
    while (ok && len - off >= 2) {
        NSUInteger i = off + 1, remaining = 0, multiplier = 1;
        BOOL complete = NO;
        int lengthBytes = 0;
        while (i < len && lengthBytes < 4) {
            uint8_t b = p[i++];
            lengthBytes++;
            remaining += (NSUInteger)(b & 0x7F) * multiplier;
            multiplier *= 128;
            if (!(b & 0x80)) { complete = YES; break; }
        }
        if (!complete) {
            if (lengthBytes >= 4) {
                if (error) *error = SHMakeError(SHErrorBadResponse, @"A malformed MQTT packet.");
                ok = NO;
            }
            break;   // (otherwise the rest of the length is still on its way)
        }
        if (remaining > SHRTMaxPacket) {
            if (error) *error = SHMakeError(SHErrorBadResponse, @"An MQTT packet too large.");
            ok = NO;
            break;
        }
        if (len - i < remaining) break;
        ok = [self handlePacket:p[off] body:p + i length:remaining socket:sock error:error];
        off = i + remaining;
    }
    if (off > 0) [input replaceBytesInRange:NSMakeRange(0, off) withBytes:NULL length:0];
    return ok;
}

- (BOOL)handlePacket:(uint8_t)header body:(const uint8_t *)body length:(NSUInteger)len socket:(SHTLSSocket *)sock error:(NSError **)error
{
    switch (header >> 4) {
        case 2: {   // CONNACK: flags, return code (a payload may follow)
            int code = len >= 2 ? body[1] : 255;
            if (code == 0) _stage = 2;
            dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate realtimeConnection:self connackCode:code]; });
            return YES;
        }
        case 3: {   // PUBLISH
            int qos = (header >> 1) & 3;
            if (len < 2) return YES;
            NSUInteger topicLen = ((NSUInteger)body[0] << 8) | body[1];
            if (2 + topicLen > len) return YES;
            NSString *topic = [[NSString alloc] initWithBytes:body + 2 length:topicLen encoding:NSUTF8StringEncoding] ?: @"";
            NSUInteger o = 2 + topicLen;
            uint16_t msgId = 0;
            if (qos > 0) {
                if (o + 2 > len) return YES;
                msgId = (uint16_t)(((uint16_t)body[o] << 8) | body[o + 1]);
                o += 2;
            }
            if (qos == 1 && ![sock writeData:SHRTAckPacket(0x40, msgId) error:error]) return NO;   // PUBACK
            if (qos == 2 && ![sock writeData:SHRTAckPacket(0x50, msgId) error:error]) return NO;   // PUBREC
            if (qos > 0) _lastWrite = CFAbsoluteTimeGetCurrent();
            NSData *raw = [NSData dataWithBytes:body + o length:len - o];
            NSData *plain = SHRTInflate(raw) ?: raw;   // (every payload should be compressed; take it as it is if not)
            NSArray *events = SHRTDecode(topic, plain);
            NSUInteger bytes = plain.length;
            dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate realtimeConnection:self events:events topic:topic bytes:bytes]; });
            return YES;
        }
        case 4: {   // PUBACK
            if (len < 2) return YES;
            uint16_t msgId = (uint16_t)(((uint16_t)body[0] << 8) | body[1]);
            dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate realtimeConnection:self acked:msgId]; });
            return YES;
        }
        case 6: {   // PUBREL (of a QoS 2 publish): PUBCOMP
            if (len < 2) return YES;
            uint16_t msgId = (uint16_t)(((uint16_t)body[0] << 8) | body[1]);
            if (![sock writeData:SHRTAckPacket(0x70, msgId) error:error]) return NO;
            _lastWrite = CFAbsoluteTimeGetCurrent();
            return YES;
        }
        case 13:    // PINGRESP
            _pingSentAt = 0;
            return YES;
        default:    // SUBACK, UNSUBACK, PUBREC/PUBCOMP of nothing we sent …
            return YES;
    }
}

@end

#pragma mark - SHRealtime

typedef enum {
    SHRTIdle = 0,
    SHRTConnecting,
    SHRTConnected,   // CONNACK accepted, the message sync not confirmed yet
    SHRTLive,
} SHRTState;

@interface SHRealtime () <SHRealtimeConnectionDelegate>
@end

@implementation SHRealtime {
    BOOL _started;
    BOOL _observing;
    SHRealtimeConnection *_conn;
    SHRTState _state;
    long long _seqId, _snapshotMs;
    BOOL _haveSeq;
    BOOL _seqStale;            // Instagram refused the position: the next inbox's is taken, older or not
    BOOL _freshInboxAsked;     // (once per connection)
    uint16_t _msgId;
    uint16_t _irisMsgId;
    NSUInteger _irisGeneration;
    BOOL _irisRetried;
    NSUInteger _retryGeneration;
    NSUInteger _failures;
    CFAbsoluteTime _liveSince;
    NSInteger _authForm;       // 0 = "authorization=Bearer IGT:2:…", 1 = "sessionid=…"
    NSInteger _authRefusals;
    CFAbsoluteTime _pausedUntil;
}

+ (instancetype)shared
{
    static SHRealtime *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[SHRealtime alloc] init]; });
    return s;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _authForm = [[NSUserDefaults standardUserDefaults] integerForKey:SHRTAuthFormKey] == 1 ? 1 : 0;
    }
    return self;
}

- (BOOL)live { return _state == SHRTLive; }

- (void)setState:(SHRTState)state
{
    BOOL wasLive = _state == SHRTLive;
    _state = state;
    BOOL live = state == SHRTLive;
    if (live && !wasLive) _liveSince = CFAbsoluteTimeGetCurrent();
    if (live != wasLive) {
        RTLog(@"%@", live ? @"live: messages arrive by the connection" : @"not live: polling as before");
        [[NSNotificationCenter defaultCenter] postNotificationName:SHRealtimeStateDidChangeNotification object:self];
    }
}

#pragma mark Lifecycle

- (void)start
{
    if (!_observing) {
        _observing = YES;
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(appBecameActive) name:UIApplicationDidBecomeActiveNotification object:nil];
        [nc addObserver:self selector:@selector(appEnteredBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [nc addObserver:self selector:@selector(settingsChanged) name:SHSettingsDidChangeNotification object:nil];
    }
    _started = YES;
    [self connectIfPossible];
}

- (void)stop
{
    _started = NO;
    [self disconnect];
    _haveSeq = NO;
    _seqStale = NO;
    _seqId = _snapshotMs = 0;
    _failures = 0;
    _authRefusals = 0;
    _pausedUntil = 0;
}

- (void)disconnect
{
    _retryGeneration++;
    _irisGeneration++;
    SHRealtimeConnection *c = _conn;
    _conn = nil;
    [c close:YES];
    [self setState:SHRTIdle];
}

- (void)appBecameActive
{
    if (!_started) return;
    _retryGeneration++;   // (in front again: now, not after the pause that was running)
    [self connectIfPossible];
}

- (void)appEnteredBackground
{
    if (!_conn) return;
    RTLog(@"background: disconnecting");
    [self disconnect];
}

- (void)settingsChanged
{
    if (_started && ![SHSettings isLoggedIn]) [self stop];
}

- (void)noteInboxSeqId:(long long)seqId snapshotAt:(long long)snapshotMs
{
    if (seqId <= 0) return;
    BOOL taken = !_haveSeq || _seqStale || seqId > _seqId;
    if (taken) {
        _seqId = seqId;
        _snapshotMs = snapshotMs > 0 ? snapshotMs : SHRTNowMs();
    }
    _haveSeq = YES;
    if (_seqStale && taken) {
        _seqStale = NO;
        if (_state == SHRTConnected) [self subscribeIris];   // the same connection, the inbox's position now
        return;
    }
    if (!_conn) [self connectIfPossible];
}

#pragma mark Connecting

- (BOOL)appActive { return [UIApplication sharedApplication].applicationState == UIApplicationStateActive; }

- (void)connectIfPossible
{
    if (!_started || _conn || ![SHSettings isLoggedIn] || ![self appActive]) return;
    if (!_haveSeq) { RTLog(@"waiting for an inbox (its seq_id)"); return; }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now < _pausedUntil) { RTLog(@"refused earlier: no try for %.0f min more", (_pausedUntil - now) / 60); return; }
    NSData *packet = [self connectPacketWithAuthForm:_authForm];
    if (!packet) { RTLog(@"no session to connect with"); return; }
    _retryGeneration++;
    _irisRetried = NO;
    _freshInboxAsked = NO;
    SHRealtimeConnection *c = [[SHRealtimeConnection alloc] initWithConnectPacket:packet verify:[SHSettings verifyTLS]];
    c.delegate = self;
    _conn = c;
    [self setState:SHRTConnecting];
    RTLog(@"connecting to %@ (password form %ld, seq_id %lld)", SHRTHost, (long)_authForm, _seqId);
    [c open];
}

- (void)retryIn:(NSTimeInterval)delay
{
    NSUInteger generation = ++_retryGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation == self->_retryGeneration) [self connectIfPossible];
    });
}

// Growing pauses between tries (a little uneven, so that many devices do not come back at once).
- (void)scheduleReconnect
{
    if (!_started || ![self appActive]) return;
    static const NSTimeInterval steps[] = { 2, 5, 15, 30, 60, 120, 300 };
    NSUInteger n = sizeof(steps) / sizeof(steps[0]);
    NSTimeInterval delay = steps[MIN(_failures, n - 1)] * (0.8 + 0.4 * (arc4random_uniform(1000) / 1000.0));
    _failures++;
    RTLog(@"next try in %.0f s", delay);
    [self retryIn:delay];
}

// Instagram did not take the session: the other form of the password once, a little later; then nothing for a while.
- (void)refused:(int)code
{
    _authRefusals++;
    if (_authRefusals == 1) {
        _authForm = 1 - _authForm;
        RTLog(@"refused (%d): trying the other password form", code);
        [self retryIn:5];
        return;
    }
    _authRefusals = 0;
    _authForm = 1 - _authForm;
    _pausedUntil = CFAbsoluteTimeGetCurrent() + SHRTRefusedPause;
    RTLog(@"refused again (%d): polling only, next try in %.0f min", code, SHRTRefusedPause / 60);
}

// The CONNECT payload: a Thrift RealtimeConfig of an Android app in front (notes/realtime-mqtt.md), compressed.
- (NSData *)connectPacketWithAuthForm:(NSInteger)form
{
    NSString *token = [SHSettings sessionToken];
    if (!token.length) return nil;
    NSDictionary *claims = SHDict([SHUtils JSONObjectFromData:[SHUtils base64Decode:token]]);
    NSString *uid = [SHSettings userId].length ? [SHSettings userId] : SHStr(claims[@"ds_user_id"]);
    if (!uid.length) return nil;
    NSString *password = nil;
    if (form == 1) {
        NSString *sid = SHStr(claims[@"sessionid"]);
        if (!sid.length) return nil;
        password = [@"sessionid=" stringByAppendingString:sid];
    } else {
        password = [@"authorization=Bearer IGT:2:" stringByAppendingString:token];
    }
    NSString *phoneId = [SHSettings phoneId].length ? [SHSettings phoneId] : ([SHSettings deviceId] ?: @"");
    NSString *ua = [SHInstagram appUserAgent];
    NSDictionary *everclear = @{
        @"inapp_notification_subscribe_comment": @"17899377895239777",
        @"inapp_notification_subscribe_comment_mention_and_reply": @"17899377895239777",
        @"video_call_participant_state_delivery": @"17977239895057311",
        @"presence_subscribe": @"17846944882223835",
    };
    NSData *everclearData = [SHUtils JSONDataFromObject:everclear];
    NSString *everclearJSON = (everclearData ? [[NSString alloc] initWithData:everclearData encoding:NSUTF8StringEncoding] : nil) ?: @"{}";

    SHThriftWriter *w = [[SHThriftWriter alloc] init];
    [w binary:(phoneId.length > 20 ? [phoneId substringToIndex:20] : phoneId) field:1];   // clientIdentifier
    [w beginStruct:4];                                                                  // clientInfo
    [w i64:[uid longLongValue] field:1];                                                // userId
    [w binary:ua field:2];                                                              // userAgent
    [w i64:183 field:3];                                                                // clientCapabilities
    [w i64:0 field:4];                                                                  // endpointCapabilities
    [w i32:1 field:5];                                                                  // publishFormat
    [w boolean:NO field:6];                                                             // noAutomaticForeground
    [w boolean:YES field:7];                                                            // makeUserAvailableInForeground
    [w binary:phoneId field:8];                                                         // deviceId
    [w boolean:YES field:9];                                                            // isInitiallyForeground
    [w i32:1 field:10];                                                                 // networkType (Wi-Fi)
    [w i32:0 field:11];                                                                 // networkSubtype
    [w i64:(SHRTNowMs() & 0xFFFFFFFFLL) field:12];                                      // clientMqttSessionId
    [w i32List:@[ @88, @135, @149, @150, @133, @146, @34 ] field:14];                   // subscribeTopics
    [w binary:@"cookie_auth" field:15];                                                 // clientType
    [w i64:567067343352427LL field:16];                                                 // appId
    [w binary:@"" field:20];                                                            // deviceSecret
    [w byte:3 field:21];                                                                // clientStack
    [w endStruct];
    [w binary:password field:5];
    [w stringMap:@{
        @"app_version": [SHInstagram appVersionName],
        @"X-IG-Capabilities": [SHInstagram capabilitiesHeader],
        @"everclear_subscriptions": everclearJSON,
        @"User-Agent": ua,
        @"Accept-Language": @"en-US",
        @"platform": @"android",
        @"ig_mqtt_route": @"django",
        @"pubsub_msg_type_blacklist": @"direct, typing_type",
        @"auth_cache_enabled": @"0",
    } field:10];                                                                        // appSpecificInfo
    [w stop];
    NSData *zipped = SHRTDeflate(w.data);
    return zipped ? SHRTConnectPacket(zipped) : nil;
}

// A JSON object to a topic (compressed, QoS 1). Answers the packet id.
- (uint16_t)publish:(NSString *)topic object:(id)object
{
    NSData *json = [SHUtils JSONDataFromObject:object];
    NSData *zipped = json.length ? SHRTDeflate(json) : nil;
    if (!zipped || !_conn) return 0;
    if (++_msgId == 0) _msgId = 1;
    [_conn send:SHRTPublishPacket(topic, zipped, _msgId)];
    RTLog(@"-> %@ (%lu B)", topic, (unsigned long)json.length);
    return _msgId;
}

- (void)subscribeIris
{
    if (!_conn || _state < SHRTConnected) return;
    NSDictionary *body = @{
        @"seq_id": @(_seqId),
        @"snapshot_at_ms": @(_snapshotMs),
        @"snapshot_app_version": [SHInstagram appVersionName],
        @"timezone_offset": @([[NSTimeZone localTimeZone] secondsFromGMT]),
        @"subscription_type": @"message",
    };
    _irisMsgId = [self publish:SHRTTopicIrisSub object:body];
    RTLog(@"iris subscribe from seq_id %lld", _seqId);
    NSUInteger generation = ++_irisGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SHRTIrisWait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self->_irisGeneration || self->_state != SHRTConnected) return;
        if (!self->_irisRetried) {
            self->_irisRetried = YES;
            RTLog(@"no answer to the iris subscribe: once more");
            [self subscribeIris];
        } else {
            RTLog(@"no answer to the iris subscribe: staying connected, polling as before");
        }
    });
}

- (void)irisAnswered:(NSDictionary *)json
{
    _irisGeneration++;   // (the wait is over)
    NSString *errorType = SHStr(json[@"error_type"]);
    BOOL ok = json[@"succeeded"] ? SHBool(json[@"succeeded"]) : !errorType.length;
    if (!ok) {
        RTLog(@"iris subscribe refused: %@ %@", errorType ?: @"-", SHStr(json[@"error_message"]) ?: @"");
        _seqStale = YES;
        if (!_freshInboxAsked) {
            _freshInboxAsked = YES;   // a fresh inbox brings a fresh position (noteInboxSeqId subscribes again)
            [SHInstagram directInboxWithCursor:nil completion:^(NSArray *threads, NSString *cursor, NSError *error) {}];
        }
        return;
    }
    long long latest = [SHStr(json[@"latest_seq_id"]) longLongValue];
    if (latest > _seqId) {
        RTLog(@"iris: Instagram is at seq_id %lld (from %lld)", latest, _seqId);
        _seqId = latest;
        long long at = [SHStr(json[@"subscribed_at_ms"]) longLongValue];
        _snapshotMs = at > 0 ? at : SHRTNowMs();
    }
    [self setState:SHRTLive];
}

#pragma mark SHRealtimeConnectionDelegate

- (void)realtimeConnection:(SHRealtimeConnection *)connection connackCode:(int)code
{
    if (connection != _conn) return;
    if (code != 0) {
        RTLog(@"CONNACK refused: %d", code);
        _conn = nil;
        [connection close:NO];
        [self setState:SHRTIdle];
        if (code == 4 || code == 5) [self refused:code];
        else [self scheduleReconnect];
        return;
    }
    _authRefusals = 0;
    [[NSUserDefaults standardUserDefaults] setInteger:_authForm forKey:SHRTAuthFormKey];
    [self setState:SHRTConnected];
    RTLog(@"connected (CONNACK 0)");
    NSString *uid = [SHSettings userId] ?: @"";
    NSData *input = [SHUtils JSONDataFromObject:@{ @"input_data": @{ @"user_id": uid } }];
    NSString *typing = [NSString stringWithFormat:@"1/graphqlsubscriptions/%@/%@", SHRTTypingQueryId,
                        input ? [[NSString alloc] initWithData:input encoding:NSUTF8StringEncoding] : @"{}"];
    [self publish:SHRTTopicRealtimeSub object:@{ @"sub": @[ typing ] }];
    [self publish:SHRTTopicPubsub object:@{ @"sub": @[ [@"ig/u/v1/" stringByAppendingString:uid] ] }];
    [self subscribeIris];
}

- (void)realtimeConnection:(SHRealtimeConnection *)connection acked:(uint16_t)msgId
{
    if (connection != _conn) return;
    if (msgId == _irisMsgId) RTLog(@"iris subscribe acknowledged");
}

- (void)realtimeConnection:(SHRealtimeConnection *)connection closedWithError:(NSError *)error stage:(int)stage serverClosed:(BOOL)serverClosed
{
    if (connection != _conn) return;
    _conn = nil;
    BOOL stable = _state == SHRTLive && CFAbsoluteTimeGetCurrent() - _liveSince > 60;
    [self setState:SHRTIdle];
    RTLog(@"closed%@: %@", stage == 1 ? @" before CONNACK" : @"", error.localizedDescription ?: @"-");
    if (stable) _failures = 0;
    if (stage == 1 && serverClosed) { [self refused:-1]; return; }   // hung up on the CONNECT: as good as refused
    [self scheduleReconnect];
}

- (void)realtimeConnection:(SHRealtimeConnection *)connection events:(NSArray *)events topic:(NSString *)topic bytes:(NSUInteger)bytes
{
    if (connection != _conn) return;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    for (NSDictionary *e in events) {
        NSString *kind = e[@"kind"];
        NSString *thread = e[@"thread"];
        if ([kind isEqualToString:@"seq"]) {
            long long seq = [e[@"seq"] longLongValue];
            if (seq > _seqId) { _seqId = seq; _snapshotMs = SHRTNowMs(); }
        } else if ([kind isEqualToString:@"iris"]) {
            [self irisAnswered:e[@"json"]];
        } else if ([kind isEqualToString:@"reconnect"]) {
            RTLog(@"<- %@: the server asks for a new connection", topic);
            [self disconnect];
            [self retryIn:1];
            return;
        } else if ([kind isEqualToString:@"item"]) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[SHRealtimeThreadKey] = thread;
            info[SHRealtimeOpKey] = e[@"op"] ?: @"add";
            info[SHRealtimeItemIdKey] = e[@"item"];
            if (e[@"json"]) info[SHRealtimeItemKey] = e[@"json"];
            RTLog(@"<- item %@ thread %@ item %@ type %@", info[SHRealtimeOpKey], thread, e[@"item"], SHStr(SHDict(e[@"json"])[@"item_type"]) ?: @"-");
            [nc postNotificationName:SHRealtimeDirectItemNotification object:self userInfo:info];
        } else if ([kind isEqualToString:@"seen"]) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[SHRealtimeThreadKey] = thread;
            info[SHRealtimeUserKey] = e[@"user"];
            if (e[@"item"]) info[SHRealtimeItemIdKey] = e[@"item"];
            if (e[@"date"]) info[SHRealtimeDateKey] = e[@"date"];
            RTLog(@"<- seen thread %@ by %@", thread, e[@"user"]);
            [nc postNotificationName:SHRealtimeDirectSeenNotification object:self userInfo:info];
        } else if ([kind isEqualToString:@"typing"]) {
            BOOL typing = [e[@"status"] integerValue] != 0;
            RTLog(@"<- typing %d thread %@ by %@", typing, thread, e[@"user"]);
            [nc postNotificationName:SHRealtimeDirectTypingNotification object:self
                            userInfo:@{ SHRealtimeThreadKey: thread, SHRealtimeUserKey: e[@"user"], SHRealtimeTypingKey: @(typing),
                                        SHRealtimeTTLKey: e[@"ttl"] ?: @12 }];
        } else if ([kind isEqualToString:@"thread"] || [kind isEqualToString:@"inbox"]) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            if (thread) info[SHRealtimeThreadKey] = thread;
            info[SHRealtimeOpKey] = e[@"op"] ?: @"";
            RTLog(@"<- %@ %@ %@", kind, e[@"op"] ?: @"", e[@"path"] ?: @"");
            [nc postNotificationName:SHRealtimeInboxChangedNotification object:self userInfo:info];
        } else {
            RTLog(@"<- topic %@ (%lu B) %@", topic, (unsigned long)bytes, e[@"path"] ?: @"");
        }
    }
}

@end
