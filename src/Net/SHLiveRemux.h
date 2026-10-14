#import <Foundation/Foundation.h>

// A live FLV stream - all TikTok hands a visitor for a live room - repacked on the device into what the iOS 6 player
// plays: the FLV's H.264 pictures and AAC sound go unchanged into MPEG-TS segments, cut at key frames about every two
// seconds and listed in a sliding live HLS playlist. Nothing is decoded or re-encoded; the stream comes straight from
// TikTok's CDN. One instance per stream, reading on a thread of its own until stopped or no longer asked for.
@interface SHLiveRemux : NSObject

- (instancetype)initWithURL:(NSURL *)url headers:(NSDictionary *)headers;
- (void)start;
- (void)stop;

@property (atomic, readonly) BOOL stopped;
@property (atomic, readonly, copy) NSString *failure;       // why it stopped by itself

// The live playlist ("<n>.ts" segments) once `count` segments are there (or the stream ended); nil after `timeout`
- (NSString *)playlistWaitingForSegments:(NSUInteger)count timeout:(NSTimeInterval)timeout;
// One segment, waiting up to `timeout` for one still being made; nil when it is gone or never came
- (NSData *)segment:(NSUInteger)sequence waiting:(NSTimeInterval)timeout;

@end
