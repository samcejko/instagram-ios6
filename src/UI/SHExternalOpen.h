#import <UIKit/UIKit.h>

// Where a web link leaves the app. Opening a link (a tap on one in a caption, a comment or a bio; a button): on iOS 6 a
// sheet asks where - Safari, or Surfari (the iOS 6 browser of this family) when it is installed; iOS 7 and newer open
// it at once. A link to YouTube, Twitch or Kick is offered to the sister app (Tubie, Twitcher, Kicker) first, on every
// iOS, when that app is installed - the only case in which iOS 7 and newer show a sheet. Sharing a link is the same
// sheet with "Copy link" first on iOS 6 and the system's share sheet on iOS 7 and newer (iPad: a popover from the
// anchor). The sheets' delegates keep themselves alive until the sheet is gone.
@interface SHExternalOpen : NSObject

+ (void)presentOpenInForURL:(NSURL *)url from:(UIViewController *)controller anchor:(UIView *)anchor;
+ (void)presentShareSheetForURL:(NSURL *)url from:(UIViewController *)controller anchor:(UIView *)anchor;

// Whether Surfari is installed (its URL scheme answers)
+ (BOOL)surfariAvailable;
// The sister app a link belongs to, when it is installed: "Tubie" (youtube.com, youtu.be), "Twitcher" (twitch.tv),
// "Kicker" (kick.com); nil for every other link and when the app is missing
+ (NSString *)sisterAppForURL:(NSURL *)url;

// Straight to one of them, no sheet (for a menu that lists them itself, like the video's hold menu)
+ (void)openInSafari:(NSURL *)url;
+ (void)openInSurfari:(NSURL *)url;             // (Safari when Surfari is not installed)
+ (BOOL)openInSisterApp:(NSURL *)url;           // NO when no installed sister app takes the link

// A sheet of one's own, shown the way the chooser is: on the iPad a popover from the anchor (when there is one),
// else over the whole screen (from the view that fills it, not from a panel or the comments sheet that would cut it)
+ (void)showSheet:(UIActionSheet *)sheet from:(UIViewController *)controller anchor:(UIView *)anchor;

@end
