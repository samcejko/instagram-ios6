#import "SHFeedCell.h"
#import "SHTabIcons.h"
#import "SHModels.h"
#import "SHImageLoader.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHCommon.h"

static const CGFloat SHHeaderH = 50;
static const CGFloat SHAvatarSize = 34;
static const CGFloat SHPadding = 10;
static const CGFloat SHButtonsH = 30;
static const CGFloat SHButtonsRow = 46;    // the row of buttons with its margins
static const CGFloat SHLikesH = 20;
static const CGFloat SHCaptionFont = 13;
static const NSInteger SHCaptionLines = 3;

@interface SHFeedCell ()
@property (nonatomic, strong) UIImageView *headerView;
@property (nonatomic, strong) SHImageView *avatarView;
@property (nonatomic, strong) UILabel *usernameLabel;
@property (nonatomic, strong) UIImageView *clockView;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) SHImageView *photoView;
@property (nonatomic, strong) UIImageView *videoMark;
@property (nonatomic, strong) UIButton *likeButton;
@property (nonatomic, strong) UIButton *commentButton;
@property (nonatomic, strong) UIButton *saveButton;
@property (nonatomic, strong) UIImageView *likesHeart;
@property (nonatomic, strong) UILabel *likesLabel;
@property (nonatomic, strong) UILabel *captionLabel;
@property (nonatomic, strong) UIView *groove;          // the etched end of a post
@property (nonatomic, strong, readwrite) SHPost *post;
@end

@implementation SHFeedCell

// Height of the photo for a width: its own proportions, kept between 4:5 and 1.91:1 like Instagram's.
static CGFloat SHPhotoHeight(SHPost *post, CGFloat width)
{
    CGFloat h = width;
    if (post.image && post.image.width > 0 && post.image.height > 0) {
        h = width * ((CGFloat)post.image.height / (CGFloat)post.image.width);
        h = MIN(h, width * 1.25f);
        h = MAX(h, width / 1.91f);
    }
    return floorf(h);
}

static NSString *SHCaptionText(SHPost *post)
{
    if (!post.captionText.length) return nil;
    return [NSString stringWithFormat:@"%@ %@", post.user.username ?: @"", [SHUtils displayText:post.captionText]];
}

static CGFloat SHCaptionHeight(SHPost *post, CGFloat width)
{
    NSString *text = SHCaptionText(post);
    if (!text.length) return 0;
    UIFont *font = [UIFont systemFontOfSize:SHCaptionFont];
    CGFloat maxH = ceilf(font.lineHeight * SHCaptionLines);
    CGSize sz = [text sizeWithFont:[UIFont boldSystemFontOfSize:SHCaptionFont] constrainedToSize:CGSizeMake(width, maxH)
                     lineBreakMode:NSLineBreakByWordWrapping];
    return MIN(maxH, ceilf(sz.height));
}

+ (CGFloat)heightForPost:(SHPost *)post width:(CGFloat)width
{
    CGFloat h = SHHeaderH + SHPhotoHeight(post, width) + SHButtonsRow + SHLikesH;
    CGFloat caption = SHCaptionHeight(post, width - SHPadding * 2);
    if (caption > 0) h += caption + 4;
    return h + 14;
}

- (UIButton *)glossyButtonWithTitle:(NSString *)title action:(SEL)action
{
    SHTheme *theme = [SHTheme shared];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setBackgroundImage:[theme buttonImageHighlighted:NO] forState:UIControlStateNormal];
    [b setBackgroundImage:[theme buttonImageHighlighted:YES] forState:UIControlStateHighlighted];
    if (title) {
        [b setTitle:title forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        [b setTitleColor:[theme textColor] forState:UIControlStateNormal];
        b.titleEdgeInsets = UIEdgeInsetsMake(0, 6, 0, 0);
        b.imageEdgeInsets = UIEdgeInsetsMake(0, -2, 0, 0);
        [theme embossButton:b];
    }
    b.adjustsImageWhenHighlighted = NO;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        SHTheme *theme = [SHTheme shared];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];

        _headerView = [[UIImageView alloc] initWithImage:[theme headerBarImage]];
        _headerView.userInteractionEnabled = YES;
        [_headerView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(userTapped)]];
        [self.contentView addSubview:_headerView];

        _avatarView = [[SHImageView alloc] initWithFrame:CGRectMake(SHPadding, (SHHeaderH - SHAvatarSize) / 2, SHAvatarSize, SHAvatarSize)];
        [theme styleAvatar:_avatarView radius:4];
        _avatarView.maxPixels = 96;
        [_headerView addSubview:_avatarView];

        _usernameLabel = [[UILabel alloc] init];
        _usernameLabel.font = [UIFont boldSystemFontOfSize:14];
        _usernameLabel.textColor = [theme textColor];
        _usernameLabel.backgroundColor = [UIColor clearColor];
        [theme embossLabel:_usernameLabel];
        [_headerView addSubview:_usernameLabel];

        _clockView = [[UIImageView alloc] initWithImage:[theme clockGlyph]];
        [_headerView addSubview:_clockView];
        _timeLabel = [[UILabel alloc] init];
        _timeLabel.font = [UIFont boldSystemFontOfSize:11];
        _timeLabel.textColor = [theme secondaryTextColor];
        _timeLabel.backgroundColor = [UIColor clearColor];
        _timeLabel.textAlignment = NSTextAlignmentRight;
        [theme embossLabel:_timeLabel];
        [_headerView addSubview:_timeLabel];

        _photoView = [[SHImageView alloc] init];
        _photoView.contentMode = UIViewContentModeScaleAspectFill;
        _photoView.clipsToBounds = YES;
        _photoView.backgroundColor = theme.isDark ? [UIColor colorWithWhite:0.12 alpha:1] : [UIColor colorWithWhite:0.85 alpha:1];
        _photoView.userInteractionEnabled = YES;
        _photoView.maxPixels = 800;
        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(imageDoubleTapped)];
        doubleTap.numberOfTapsRequired = 2;
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(imageTapped)];
        [tap requireGestureRecognizerToFail:doubleTap];
        [_photoView addGestureRecognizer:tap];
        [_photoView addGestureRecognizer:doubleTap];
        [self.contentView addSubview:_photoView];

        _videoMark = [[UIImageView alloc] initWithImage:[theme playButtonImageWithSize:54]];
        _videoMark.hidden = YES;
        [_photoView addSubview:_videoMark];

        _likeButton = [self glossyButtonWithTitle:L(@"Like") action:@selector(likeTapped)];
        [self.contentView addSubview:_likeButton];
        _commentButton = [self glossyButtonWithTitle:L(@"Comment") action:@selector(commentTapped)];
        [_commentButton setImage:[SHTabIcons commentBubbleWithSize:16 color:[theme textColor] dark:theme.isDark] forState:UIControlStateNormal];
        [self.contentView addSubview:_commentButton];
        _saveButton = [self glossyButtonWithTitle:nil action:@selector(saveTapped)];
        [self.contentView addSubview:_saveButton];

        _likesHeart = [[UIImageView alloc] initWithImage:[SHTabIcons heartWithSize:13 filled:YES color:[theme linkColor] dark:theme.isDark]];
        [self.contentView addSubview:_likesHeart];
        _likesLabel = [[UILabel alloc] init];
        _likesLabel.font = [UIFont boldSystemFontOfSize:13];
        _likesLabel.textColor = [theme linkColor];
        _likesLabel.backgroundColor = [UIColor clearColor];
        [theme embossLabel:_likesLabel];
        [self.contentView addSubview:_likesLabel];

        _captionLabel = [[UILabel alloc] init];
        _captionLabel.numberOfLines = SHCaptionLines;
        _captionLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _captionLabel.backgroundColor = [UIColor clearColor];
        _captionLabel.shadowColor = theme.isDark ? [UIColor colorWithWhite:0 alpha:0.8] : [UIColor colorWithWhite:1 alpha:0.9];
        _captionLabel.shadowOffset = theme.isDark ? CGSizeMake(0, -1) : CGSizeMake(0, 1);
        [self.contentView addSubview:_captionLabel];

        _groove = [[UIView alloc] init];
        UIView *dark = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 1)];
        dark.backgroundColor = [UIColor colorWithWhite:0 alpha:theme.isDark ? 0.8 : 0.2];
        dark.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        UIView *light = [[UIView alloc] initWithFrame:CGRectMake(0, 1, 10, 1)];
        light.backgroundColor = [UIColor colorWithWhite:1 alpha:theme.isDark ? 0.07 : 0.8];
        light.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        _groove.frame = CGRectMake(0, 0, 10, 2);
        [_groove addSubview:dark];
        [_groove addSubview:light];
        [self.contentView addSubview:_groove];
    }
    return self;
}

- (void)configureWithPost:(SHPost *)post
{
    SHTheme *theme = [SHTheme shared];
    _post = post;
    _usernameLabel.text = post.user.username;
    _timeLabel.text = post.takenAt ? [SHUtils formatRelativeDate:post.takenAt] : @"";
    _likesLabel.text = [NSString stringWithFormat:L(@"%@ likes"), [SHUtils formatCount:post.likeCount]];

    UIColor *heartColor = post.hasLiked ? [UIColor colorWithRed:0.93 green:0.2 blue:0.27 alpha:1] : [theme textColor];
    [_likeButton setImage:[SHTabIcons heartWithSize:16 filled:post.hasLiked color:heartColor dark:theme.isDark] forState:UIControlStateNormal];
    [_likeButton setBackgroundImage:[theme buttonImageHighlighted:post.hasLiked] forState:UIControlStateNormal];   // pressed in once liked
    [_saveButton setImage:[SHTabIcons bookmarkWithSize:16 filled:post.saved color:[theme textColor] dark:theme.isDark] forState:UIControlStateNormal];

    NSString *caption = SHCaptionText(post);
    if (caption.length) {
        NSUInteger nameLength = MIN(caption.length, post.user.username.length);
        NSMutableAttributedString *cap = [[NSMutableAttributedString alloc] initWithString:caption attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:SHCaptionFont], NSForegroundColorAttributeName: [theme textColor] }];
        [cap addAttributes:@{ NSFontAttributeName: [UIFont boldSystemFontOfSize:SHCaptionFont], NSForegroundColorAttributeName: [theme linkColor] }
                     range:NSMakeRange(0, nameLength)];
        _captionLabel.attributedText = cap;
    } else {
        _captionLabel.attributedText = nil;
        _captionLabel.text = nil;
    }

    _videoMark.hidden = !(post.mediaType == 2 || post.videoURL.length);
    [_avatarView setImageURL:post.user.profilePicURL placeholder:[theme avatarPlaceholderWithSize:SHAvatarSize]];
    [_photoView setImageURL:post.mediumImage.url ?: post.image.url placeholder:nil];
    [self setNeedsLayout];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;

    _headerView.frame = CGRectMake(0, 0, w, SHHeaderH);
    CGSize timeSize = [_timeLabel.text sizeWithFont:_timeLabel.font];
    _timeLabel.frame = CGRectMake(w - SHPadding - timeSize.width, 0, timeSize.width, SHHeaderH);
    _clockView.frame = CGRectMake(_timeLabel.frame.origin.x - 16, floorf((SHHeaderH - 12) / 2), 12, 12);
    CGFloat nameX = SHPadding + SHAvatarSize + 10;
    _usernameLabel.frame = CGRectMake(nameX, 0, _clockView.frame.origin.x - nameX - 8, SHHeaderH);
    CGFloat y = SHHeaderH;

    CGFloat imgH = SHPhotoHeight(_post, w);
    _photoView.frame = CGRectMake(0, y, w, imgH);
    _videoMark.frame = CGRectMake(floorf((w - 54) / 2), floorf((imgH - 54) / 2), 54, 54);
    y += imgH;

    CGFloat by = y + (SHButtonsRow - SHButtonsH) / 2;
    CGFloat likeW = MAX(96, [[_likeButton titleForState:UIControlStateNormal] sizeWithFont:_likeButton.titleLabel.font].width + 46);
    CGFloat commentW = MAX(96, [[_commentButton titleForState:UIControlStateNormal] sizeWithFont:_commentButton.titleLabel.font].width + 46);
    _likeButton.frame = CGRectMake(SHPadding, by, likeW, SHButtonsH);
    _commentButton.frame = CGRectMake(SHPadding + likeW + 8, by, commentW, SHButtonsH);
    _saveButton.frame = CGRectMake(w - SHPadding - 40, by, 40, SHButtonsH);
    y += SHButtonsRow;

    _likesHeart.frame = CGRectMake(SHPadding, y + 3, _likesHeart.image.size.width, _likesHeart.image.size.height);
    _likesLabel.frame = CGRectMake(SHPadding + 19, y, w - SHPadding * 2 - 19, SHLikesH - 2);
    y += SHLikesH;

    CGFloat capH = SHCaptionHeight(_post, w - SHPadding * 2);
    _captionLabel.hidden = capH <= 0;
    if (capH > 0) {
        _captionLabel.frame = CGRectMake(SHPadding, y, w - SHPadding * 2, capH);
        y += capH + 4;
    }
    _groove.frame = CGRectMake(0, self.contentView.bounds.size.height - 2, w, 2);
}

#pragma mark - Actions

- (void)userTapped
{
    if ([_delegate respondsToSelector:@selector(feedCell:didTapUser:username:)])
        [_delegate feedCell:self didTapUser:_post.user.pk username:_post.user.username];
}

- (void)likeTapped
{
    if ([_delegate respondsToSelector:@selector(feedCell:didTapLikeOnPost:)])
        [_delegate feedCell:self didTapLikeOnPost:_post];
}

- (void)commentTapped
{
    if ([_delegate respondsToSelector:@selector(feedCell:didTapCommentOnPost:)])
        [_delegate feedCell:self didTapCommentOnPost:_post];
}

- (void)saveTapped
{
    if ([_delegate respondsToSelector:@selector(feedCell:didTapSaveOnPost:)])
        [_delegate feedCell:self didTapSaveOnPost:_post];
}

- (void)imageTapped
{
    if ([_delegate respondsToSelector:@selector(feedCell:didTapImageOnPost:)])
        [_delegate feedCell:self didTapImageOnPost:_post];
}

- (void)imageDoubleTapped
{
    if (!_post.hasLiked) [self likeTapped];
}

@end
