#import <Foundation/Foundation.h>

// The media player of iOS 6 (AVPlayer) loads streams with the system's own network stack, which cannot talk to
// YouTube's servers: they only accept current TLS ciphers. This small HTTP server on 127.0.0.1 hands the stream to
// the player through the app's network layer (SHTLSSocket) instead:
//   - HLS playlists are fetched, cleaned of the tags the 2012 player does not know and rewritten so that their
//     segments, sound renditions and nested playlists come through the proxy too,
//   - segments and MP4 files are passed on as they arrive, Range requests included (seeking), with a content type
//     read from their first bytes (YouTube's URLs have no file extension).
// URLs carry a random secret, so only what the app handed out is served.
@interface SHMediaProxy : NSObject

+ (instancetype)shared;

// YES when the server listens. When the system took the listening socket away (the app was suspended for long),
// the server starts again on another port: everything handed out before is void then, `generation` counts that.
- (BOOL)ensureRunning;
@property (atomic, readonly) NSUInteger generation;

// http://127.0.0.1:<port>/<secret>/... for a playlist, a segment or a media file; nil when the server is down
- (NSString *)proxyURLForURL:(NSURL *)url;
// The same, but sends extra headers to the origin (TikTok's CDN wants Referer/User-Agent/Cookie)
- (NSString *)proxyURLForURL:(NSURL *)url upstreamHeaders:(NSDictionary *)upstreamHeaders;

// The same for a playlist the app wrote itself (the master playlist with the renditions the device can play).
// URIs in the text must already be proxy URLs.
- (NSString *)proxyURLForPlaylistText:(NSString *)text;

// A live FLV stream repacked on the device into a live HLS playlist the player can open (see SHLiveRemux). It reads
// while the player asks; -stopLiveStreams ends every one (the live screen closed).
- (NSString *)proxyURLForLiveFLV:(NSURL *)url headers:(NSDictionary *)headers;
- (void)stopLiveStreams;
- (BOOL)liveStreamRunning;     // NO once every one handed out has stopped (ended, or broken off for good)

// The media playlist served last carried a stitched-in advertisement (the player shows a note)
@property (atomic, readonly) BOOL adBreakActive;
// When the player last asked for anything (a player that stopped asking has given up)
@property (atomic, readonly) NSTimeInterval lastRequestTime;

// A new playback: forgets the ad state
- (void)resetPlaybackState;

// What was served since the start, by content type ("video/MP2T: 12 (4.1 MB), audio/aac: 12 (0.6 MB)") - for the
// debug "stats" command: it tells whether the player fetches the sound rendition at all
- (NSString *)statsDescription;
// Every request of the player goes to the log (debug mode)
@property (atomic) BOOL logRequests;

@end
