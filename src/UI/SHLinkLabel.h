#import <UIKit/UIKit.h>

typedef enum {
    SHTextLinkMention,   // "@name": the profile
    SHTextLinkHashtag,   // "#tag": the tag's posts
    SHTextLinkWeb,       // a web link (an instagram.com one opens inside the app)
    SHTextLinkUser,      // a stretch of the text standing for a person (the author's name before a caption or comment)
} SHTextLinkKind;

@interface SHTextLink : NSObject
@property (nonatomic) SHTextLinkKind kind;
@property (nonatomic) NSRange range;
@property (nonatomic, copy) NSString *value;    // the user name (no "@"), the tag (no "#"), the URL
@property (nonatomic, copy) NSString *userPk;   // SHTextLinkUser, when known
@end

// A text whose @mentions, #hashtags and web links show in the link colour and open on a tap: the mentioned profile,
// the tag's posts, the link (SHLinkRouter). iOS 6 has no TextKit to tell which word a finger hit, so the text is laid
// out and drawn with Core Text here, and the same layout answers which link lies under a point and how tall the
// text is (+sizeForAttributedText:… measures exactly what is drawn). Touches off the links go through to whatever
// lies under the label (a cell, a bubble), unless textTapHandler is set.
@interface SHLinkLabel : UIView
@property (nonatomic, copy) NSString *text;                       // in font and textColor
@property (nonatomic, copy) NSAttributedString *attributedText;   // NSFontAttributeName / NSForegroundColorAttributeName kept
@property (nonatomic, strong) UIFont *font;                       // default: system 14
@property (nonatomic, strong) UIColor *textColor;
@property (nonatomic, strong) UIColor *linkColor;                 // default: the theme's
@property (nonatomic, strong) UIColor *shadowColor;
@property (nonatomic) CGSize shadowOffset;
@property (nonatomic) NSInteger numberOfLines;                    // 0 = all; a cut text ends with "…"
@property (nonatomic) UITextAlignment textAlignment;
@property (nonatomic, strong, readonly) NSArray *links;           // SHTextLink, in the order of the text
@property (nonatomic, copy) void (^linkHandler)(SHTextLink *link);   // instead of the usual way of opening it
@property (nonatomic, copy) void (^textTapHandler)(void);            // a tap on the text off the links

// A stretch of the text that opens a person (set after the text): the bold name before a caption or a comment.
- (void)addUserLinkWithRange:(NSRange)range username:(NSString *)username pk:(NSString *)pk;

// The size the text takes at a width (the width is that of its longest line).
+ (CGSize)sizeForAttributedText:(NSAttributedString *)text width:(CGFloat)width lines:(NSInteger)lines;
+ (CGSize)sizeForText:(NSString *)text font:(UIFont *)font width:(CGFloat)width lines:(NSInteger)lines;

// Opens a link the usual way: a profile or a tag pushed where the user is, a web link through SHLinkRouter.
+ (void)openLink:(SHTextLink *)link from:(UIView *)view;
@end
