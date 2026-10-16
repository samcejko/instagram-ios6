#import <Foundation/Foundation.h>

// Instagram's live connection, as the Android app keeps it: MQTT over TLS to edge-mqtt.facebook.com ("MQTToT"), with
// the Direct message sync ("iris") subscribed from the inbox's seq_id. New messages, read receipts and typing arrive
// as they happen while the app is on screen; the pollers stay as the fallback and only slow down while it is live.
// Disconnected in the background, connected again in front, with growing pauses after failures and none at all once
// Instagram refused the session twice (until 30 minutes have passed or the app starts again).
// Everything here runs on the main thread, notifications included. Notes: notes/realtime-mqtt.md.

extern NSString * const SHRealtimeStateDidChangeNotification;     // live or not any more (object: the SHRealtime)
extern NSString * const SHRealtimeDirectItemNotification;         // a message added, changed or taken back
extern NSString * const SHRealtimeDirectSeenNotification;         // someone read a chat up to a message
extern NSString * const SHRealtimeDirectTypingNotification;       // someone is typing in a chat, or stopped
extern NSString * const SHRealtimeInboxChangedNotification;       // a chat itself changed (new, renamed, removed …)

// userInfo keys of those notifications
extern NSString * const SHRealtimeThreadKey;   // NSString: the thread id (all of them; may be absent for the inbox)
extern NSString * const SHRealtimeOpKey;       // NSString: "add", "replace" or "remove" (items, inbox)
extern NSString * const SHRealtimeItemIdKey;   // NSString: the message (items; seen: how far, when told)
extern NSString * const SHRealtimeItemKey;     // NSDictionary: the message as direct_v2 lists it (added or changed)
extern NSString * const SHRealtimeUserKey;     // NSString: who read (seen) or types (typing)
extern NSString * const SHRealtimeDateKey;     // NSDate: up to when it was read (seen)
extern NSString * const SHRealtimeTypingKey;   // NSNumber BOOL: typing now (typing)
extern NSString * const SHRealtimeTTLKey;      // NSNumber: seconds the typing holds unless told again (typing)

@interface SHRealtime : NSObject

+ (instancetype)shared;

// Connected and the message sync confirmed: what the realtime connection says can be trusted to come at once.
@property (nonatomic, readonly) BOOL live;

- (void)start;   // logged in (the tab shell is up): connect whenever the app is in front and an inbox was loaded
- (void)stop;    // logged out: disconnect and forget the account's sync position

// The message sync position of an inbox's first page (its top level "seq_id" and "snapshot_at_ms"): where the
// subscription starts. Each fresh inbox is told; the newer position wins.
- (void)noteInboxSeqId:(long long)seqId snapshotAt:(long long)snapshotMs;

@end
