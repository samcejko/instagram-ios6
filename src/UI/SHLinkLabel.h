#import <UIKit/UIKit.h>

// A label whose web links ("https://…", "www.…", "example.com/…") show in the link colour and open on a tap: a TikTok
// link inside the app, a YouTube, Twitch or Kick one in the sister app, the rest in a browser (SHLinkRouter). One link
// opens at once, several are listed in a sheet first. iOS 6 has no TextKit to tell which word a finger hit, so the
// whole label is the tap target - and it takes no touches at all while its text has no link. Set the font, colour and
// shadow before the text (they go into the text with the links); the rest is a UILabel.
@interface SHLinkLabel : UILabel
@property (nonatomic, strong) UIColor *linkColor;         // the theme's link colour unless set
@property (nonatomic, strong, readonly) NSArray *links;   // NSURL, in the order of the text (empty: none)
@end
