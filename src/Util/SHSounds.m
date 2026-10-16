#import "SHSounds.h"
#import "SHRealtime.h"
#import "SHSettings.h"
#import "SHCommon.h"
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>

// The system's sound ids of Messages: ReceivedMessage.caf and SentMessage.caf (the same on iOS 6 and later).
static const SystemSoundID SHReceivedSoundId = 1003;
static const SystemSoundID SHSentSoundId     = 1004;

@implementation SHSounds

static CFAbsoluteTime g_lastPlayed;

+ (void)play:(SystemSoundID)sound
{
    if (![SHSettings messageSounds]) return;
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - g_lastPlayed < 1.2) return;
    g_lastPlayed = now;
    AudioServicesPlaySystemSound(sound);
}

+ (void)playReceived { [self play:SHReceivedSoundId]; }
+ (void)playSent { [self play:SHSentSoundId]; }

+ (void)liveItem:(NSNotification *)note
{
    if (![note.userInfo[SHRealtimeOpKey] isEqualToString:@"add"]) return;
    NSDictionary *item = SHDict(note.userInfo[SHRealtimeItemKey]);
    NSString *sender = SHStr(item[@"user_id"]);
    NSString *me = [SHSettings userId];
    if (!sender.length || [sender isEqualToString:me ?: @""]) return;   // (mine echo back too)
    if ([SHStr(item[@"item_type"]) isEqualToString:@"action_log"]) return;   // (a line of the history, not a message)
    [self playReceived];
}

+ (void)startObservingLiveMessages
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(liveItem:)
                                                     name:SHRealtimeDirectItemNotification object:nil];
    });
}

@end
