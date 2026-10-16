#import <Foundation/Foundation.h>

// The short sounds of iOS Messages when a message comes in or goes out: the system's own (nothing is bundled), only
// while the app is on screen and the setting allows it, never more than one in a moment (a burst of messages, a
// photo sent with its text). The ring/silent switch silences them as it does Messages'.
@interface SHSounds : NSObject
+ (void)playReceived;
+ (void)playSent;
// From now on the received sound for the messages the live connection brings to any chat (the open one included).
+ (void)startObservingLiveMessages;
@end
