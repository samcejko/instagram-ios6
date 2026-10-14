#import <UIKit/UIKit.h>

// Colours, fonts and the code-drawn glossy iOS 6 artwork: a classic light look and a dark one (black bars).
// Posts SHThemeDidChangeNotification when the theme changes.
@interface SHTheme : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL isDark;
- (void)setDark:(BOOL)dark;                 // persists, posts the notification, updates the status bar
- (void)invalidateArtwork;                  // after a settings change that affects drawing

// Colours
- (UIColor *)backgroundColor;               // behind lists and grids
- (UIColor *)cardColor;                     // list rows, cards
- (UIColor *)primaryTextColor;
- (UIColor *)textColor;                     // same as primaryTextColor
- (UIColor *)secondaryTextColor;
- (UIColor *)separatorColor;
- (UIColor *)accentColor;
- (UIColor *)liveColor;                     // red
- (UIColor *)linkColor;
- (UIColor *)chatBackgroundColor;
- (UIColor *)chatTextColor;
- (UIColor *)chatSystemTextColor;
- (UIColor *)chatMentionColor;              // behind messages that name the user
- (UIColor *)chatHighlightColor;            // channel-points highlights, first messages
- (UIColor *)chatDeletedTextColor;
- (UIColor *)chatSeparatorColor;
- (UIColor *)inputTextColor;
- (UIColor *)placeholderColor;
- (UIColor *)playerBackgroundColor;

// Artwork (stretchable where it makes sense)
- (UIImage *)cardBackgroundImage;           // white glossy card with a hairline and a soft bottom shadow
- (UIImage *)cardBackgroundImageHighlighted;
- (UIImage *)pillImageWithColor:(UIColor *)color;    // small glossy capsule (LIVE, viewer counts)
- (UIImage *)darkPillImage;                 // translucent black capsule for text over thumbnails
- (UIImage *)barBackgroundImage;            // 44 pt bar (chat input)
- (UIImage *)textFieldBackgroundImage;
- (UIImage *)buttonImageHighlighted:(BOOL)highlighted;              // grey glossy button
- (UIImage *)accentButtonImageHighlighted:(BOOL)highlighted disabled:(BOOL)disabled;   // red glossy button (Subscribe)
- (UIImage *)redButtonImageHighlighted:(BOOL)highlighted;
- (UIImage *)thumbnailPlaceholder;          // dark 16:9 box with a faint play sign
- (UIImage *)boxArtPlaceholder;
- (UIImage *)avatarPlaceholderWithSize:(CGFloat)size;
- (UIImage *)sectionHeaderBackgroundImage;  // the blue-grey gradient of plain table headers
- (UIImage *)controlsGradientImageTop:(BOOL)top;      // black fade behind the player controls
// The pages (a creator, a hashtag, a sound, the topics): a shaded background with a fine grain over it, glossy
// capsules for choices, and text pressed into the surface
- (UIImage *)pageBackgroundImage;           // stretch to fill
- (UIColor *)grainColor;                    // a pattern of fine noise to lay over it
- (UIImage *)capsuleImageSelected:(BOOL)selected highlighted:(BOOL)highlighted height:(CGFloat)height;
- (UIImage *)roundButtonImageWithSize:(CGFloat)size;  // a glossy black disc (a play button over a picture)
- (UIImage *)badgeImageWithHeight:(CGFloat)height;    // a dark see-through glossy capsule (counts over pictures)
- (void)embossLabel:(UILabel *)label;       // a shadow that sets the text into the surface (by the look)
- (void)embossButton:(UIButton *)button;
- (UIColor *)embossTextColor;               // the text of the pages' labels

// Icons (template-like alpha drawings): tab bar
- (UIImage *)tabIconHome;
- (UIImage *)tabIconSubscriptions;
- (UIImage *)tabIconShorts;
- (UIImage *)tabIconSearch;
- (UIImage *)tabIconLibrary;
- (UIImage *)tabIconSettings;
// player controls, drawn in white
- (UIImage *)playIcon;
- (UIImage *)pauseIcon;
- (UIImage *)fullscreenIconEnter:(BOOL)enter;
- (UIImage *)chatIconOn:(BOOL)on;
- (UIImage *)gearIconWhite;
- (UIImage *)closeIconWhite;
- (UIImage *)backChevronWhite;
- (UIImage *)minimizeChevronWhite;          // downward chevron: minimise the player to the floating mini bar
- (UIImage *)replayIcon;                    // circular arrow, for a stream that ended
- (UIImage *)searchIconWhite;               // magnifier over the feed
- (UIImage *)discImageWithSize:(CGFloat)size;   // a black record with grooves (the sound of a video)
// misc
- (UIImage *)starIconFilled:(BOOL)filled color:(UIColor *)color size:(CGFloat)size;
- (UIImage *)liveDotImage;
- (UIImage *)emoteIcon;                     // smiley for the emote picker button
- (UIImage *)checkmarkImage;
- (UIImage *)disclosureChevronImage;        // grey chevron for custom cells

// Fonts
- (UIFont *)titleFont;                      // bold 15/17
- (UIFont *)bodyFont;
- (UIFont *)smallFont;
- (UIFont *)tinyBoldFont;
- (CGFloat)chatFontSize;                    // from the settings
- (UIFont *)chatFont;
- (UIFont *)chatBoldFont;
- (UIFont *)chatSmallFont;

// Applying to UIKit
- (UIBarStyle)barStyle;
- (UIStatusBarStyle)statusBarStyle;
- (void)applyToNavigationBar:(UINavigationBar *)bar;
- (void)applyToToolbar:(UIToolbar *)bar;
- (void)applyToTabBar:(UITabBar *)bar;
- (void)applyToTableView:(UITableView *)tableView;
- (void)styleCell:(UITableViewCell *)cell;
- (void)applyToSearchBar:(UISearchBar *)bar;
- (UIActivityIndicatorViewStyle)spinnerStyle;

@end
