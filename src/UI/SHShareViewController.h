#import <UIKit/UIKit.h>

@class SHPost;

// "Send to": a post shared into chats, as the paper plane under a post does it in the app. The recent chats are listed
// (a search finds anyone else), several can be ticked, a message can go along; the link can be copied or shared
// outside the app (Mail, Messages, Twitter, Facebook).
@interface SHShareViewController : UIViewController
- (instancetype)initWithPost:(SHPost *)post;
+ (void)presentForPost:(SHPost *)post;          // in a navigation, from where the user is (a form sheet on the iPad)
+ (NSURL *)webURLForPost:(SHPost *)post;         // https://www.instagram.com/p/<code>/
+ (void)flashMessage:(NSString *)text;           // a short dark notice in the middle of the screen ("Sent")
@end
