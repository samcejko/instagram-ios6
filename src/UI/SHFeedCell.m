#import "SHFeedCell.h"
#import "SHModels.h"
#import "SHImageLoader.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHCommon.h"

static const CGFloat SHAvatarSize = 32;
static const CGFloat SHPadding = 12;
static const CGFloat SHIconSize = 26;

@interface SHFeedCell ()
@property (nonatomic, strong) SHImageView *avatarView;
@property (nonatomic, strong) UILabel *usernameLabel;
@property (nonatomic, strong) SHImageView *photoView;
@property (nonatomic, strong) UIButton *likeButton;
@property (nonatomic, strong) UIButton *commentButton;
@property (nonatomic, strong) UILabel *likesLabel;
@property (nonatomic, strong) UILabel *captionLabel;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) SHPost *post;
@end

@implementation SHFeedCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [[SHTheme shared] backgroundColor];

        _avatarView = [[SHImageView alloc] initWithFrame:CGRectMake(SHPadding, SHPadding, SHAvatarSize, SHAvatarSize)];
        _avatarView.layer.cornerRadius = SHAvatarSize / 2;
        _avatarView.clipsToBounds = YES;
        _avatarView.backgroundColor = [[SHTheme shared] separatorColor];
        _avatarView.userInteractionEnabled = YES;
        [_avatarView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(userTapped)]];
        [self.contentView addSubview:_avatarView];

        _usernameLabel = [[UILabel alloc] init];
        _usernameLabel.font = [UIFont boldSystemFontOfSize:14];
        _usernameLabel.textColor = [[SHTheme shared] textColor];
        _usernameLabel.userInteractionEnabled = YES;
        [_usernameLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(userTapped)]];
        [self.contentView addSubview:_usernameLabel];

        _photoView = [[SHImageView alloc] init];
        _photoView.contentMode = UIViewContentModeScaleAspectFill;
        _photoView.clipsToBounds = YES;
        _photoView.backgroundColor = [[SHTheme shared] separatorColor];
        _photoView.userInteractionEnabled = YES;
        [_photoView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(imageTapped)]];
        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(imageDoubleTapped)];
        doubleTap.numberOfTapsRequired = 2;
        [_photoView addGestureRecognizer:doubleTap];
        [self.contentView addSubview:_photoView];

        _likeButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [_likeButton setTitle:@"♥" forState:UIControlStateNormal];
        _likeButton.titleLabel.font = [UIFont systemFontOfSize:24];
        [_likeButton addTarget:self action:@selector(likeTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_likeButton];

        _commentButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [_commentButton setTitle:@"\U0001F4AC" forState:UIControlStateNormal];
        _commentButton.titleLabel.font = [UIFont systemFontOfSize:22];
        [_commentButton addTarget:self action:@selector(commentTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_commentButton];

        _likesLabel = [[UILabel alloc] init];
        _likesLabel.font = [UIFont boldSystemFontOfSize:13];
        _likesLabel.textColor = [[SHTheme shared] textColor];
        [self.contentView addSubview:_likesLabel];

        _captionLabel = [[UILabel alloc] init];
        _captionLabel.font = [UIFont systemFontOfSize:13];
        _captionLabel.textColor = [[SHTheme shared] textColor];
        _captionLabel.numberOfLines = 3;
        [self.contentView addSubview:_captionLabel];

        _timeLabel = [[UILabel alloc] init];
        _timeLabel.font = [UIFont systemFontOfSize:11];
        _timeLabel.textColor = [[SHTheme shared] secondaryTextColor];
        [self.contentView addSubview:_timeLabel];

        // iOS 6 UILabels default to an opaque white background; clear them so text sits on the dark card.
        for (UILabel *l in @[ _usernameLabel, _likesLabel, _captionLabel, _timeLabel ]) l.backgroundColor = [UIColor clearColor];
    }
    return self;
}

- (void)configureWithPost:(SHPost *)post
{
    _post = post;
    _usernameLabel.text = post.user.username;
    _likesLabel.text = [NSString stringWithFormat:L(@"%@ likes"), [SHUtils formatCount:post.likeCount]];
    [_likeButton setTitleColor:post.hasLiked ? [UIColor redColor] : [[SHTheme shared] textColor] forState:UIControlStateNormal];

    if (post.captionText.length) {
        NSString *display = [SHUtils displayText:post.captionText];
        NSMutableAttributedString *cap = [[NSMutableAttributedString alloc] init];
        NSDictionary *boldAttrs = @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:13], NSForegroundColorAttributeName: [[SHTheme shared] textColor] };
        NSDictionary *bodyAttrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: [[SHTheme shared] textColor] };
        [cap appendAttributedString:[[NSAttributedString alloc] initWithString:[post.user.username stringByAppendingString:@" "] attributes:boldAttrs]];
        [cap appendAttributedString:[[NSAttributedString alloc] initWithString:display attributes:bodyAttrs]];
        _captionLabel.attributedText = cap;
    } else {
        _captionLabel.text = nil;
    }

    _timeLabel.text = post.takenAt ? [SHUtils formatRelativeDate:post.takenAt] : @"";

    [_avatarView setImageURL:post.user.profilePicURL placeholder:nil];
    [_photoView setImageURL:post.image.url placeholder:nil];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat y = SHPadding;

    _avatarView.frame = CGRectMake(SHPadding, y, SHAvatarSize, SHAvatarSize);
    _usernameLabel.frame = CGRectMake(SHPadding + SHAvatarSize + 8, y, w - SHPadding * 2 - SHAvatarSize - 8, SHAvatarSize);
    y += SHAvatarSize + 8;

    CGFloat imgH = w;
    if (_post.image && _post.image.width > 0 && _post.image.height > 0) {
        imgH = w * ((CGFloat)_post.image.height / (CGFloat)_post.image.width);
        if (imgH > w * 1.25) imgH = w * 1.25;
    }
    _photoView.frame = CGRectMake(0, y, w, imgH);
    y += imgH + 6;

    _likeButton.frame = CGRectMake(SHPadding, y, SHIconSize, SHIconSize);
    _commentButton.frame = CGRectMake(SHPadding + SHIconSize + 12, y, SHIconSize, SHIconSize);
    y += SHIconSize + 4;

    _likesLabel.frame = CGRectMake(SHPadding, y, w - SHPadding * 2, 18);
    y += 20;

    if (_captionLabel.attributedText.length || _captionLabel.text.length) {
        CGSize capSize = [_captionLabel sizeThatFits:CGSizeMake(w - SHPadding * 2, 60)];
        _captionLabel.frame = CGRectMake(SHPadding, y, w - SHPadding * 2, capSize.height);
        y += capSize.height + 4;
    }

    _timeLabel.frame = CGRectMake(SHPadding, y, w - SHPadding * 2, 16);
}

+ (CGFloat)heightForPost:(SHPost *)post width:(CGFloat)width
{
    CGFloat h = SHPadding + SHAvatarSize + 8;
    CGFloat imgH = width;
    if (post.image && post.image.width > 0 && post.image.height > 0) {
        imgH = width * ((CGFloat)post.image.height / (CGFloat)post.image.width);
        if (imgH > width * 1.25) imgH = width * 1.25;
    }
    h += imgH + 6 + SHIconSize + 4 + 18 + 20;
    if (post.captionText.length) h += 40;
    h += 16 + 10;
    return h;
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
