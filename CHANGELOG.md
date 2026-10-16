# Changelog

## 0.3.3 (2026-10-16)

- When the home feed cannot load, the screen now says why under "Couldn't load the feed." (Instagram's own words or the network error), so a screenshot tells what went wrong.
- Everything of 0.3.2: the sign-in fix for "Your session expired" on every screen.

## 0.3.2 (2026-10-16)

A fix for signing in.

- Signing in could end in "Your session expired" on every screen. The session token was read out of Instagram's reply only up to the first character Instagram writes escaped (a "/" or the "=" at its end), and an older token kept by another install of the app could win over the new one. The token is now read whole, checked with Instagram before the app opens, and kept where it is read back from.
- A session Instagram ends (signed out on another device, a password change) now leads back to the login screen once, with Instagram's reason, instead of an app whose every screen says the session expired.
- The arm64 build's live connection has been tried on an iPhone X with iOS 16: it connects.

## 0.3.1 (2026-10-16)

Direct over Instagram's live connection. Tested on an iPad 2 with iOS 6.1.3.

- New messages arrive the moment they are sent (in about two seconds), the way the official app gets them: over Instagram's own live connection instead of asking every few seconds. The open chat, the list of chats and the badge on the Direct tab all update at once.
- Typing: a bubble with three dots in the chat while the other side types, "Typing..." in the list of chats.
- "Seen" under your last message appears as soon as they have read it, and a message they unsend disappears.
- Fewer requests: while the live connection is up, the chat, the list and the badge only check every 1.5, 3 and 10 minutes, as a safety net. Without the connection (or if Instagram refuses it) everything updates as before.
- The connection is open only while the app is on screen; it comes back by itself when you return to the app or the network does.

Good to know:

- Instagram may slow down or restrict an account used from an unofficial client.
- The arm64 build (iOS 15 and newer) is the same code, but its live connection has not been tried on a device yet.

## 0.3.0 (2026-10-16)

Direct grows up, and the first version in the repository. Tested on an iPad 2 with iOS 6.1.3.

- New messages show up on their own: an open chat asks every few seconds (less often while nothing comes), the list of chats every 15 to 60 seconds, nothing while the app is in the background. A red badge on the Direct tab counts the unread chats.
- Read receipts both ways: an open chat counts as read (the sender sees "Seen"), and "Seen" appears under your last message once they have read it.
- Photos and voice messages are sent again: Instagram retired the old way, they go through its new upload now. Photos from the camera or the library, voice messages up to a minute.
- Photos and videos from the chat's camera: "keep in chat" ones show in the chat, "view once" and "allow replay" ones open full screen with a tap, and the sender sees they were opened.
- Calls in a chat's history: one line per call, a missed call in red, the length of a call.
- Follow requests to a private account in Activity, message requests above the chats: accept or delete.
- Highlights on profiles, under the bio, played like stories.
- @names, #hashtags and links in captions, comments, bios and messages open the profile, the tag's posts or the post; the people tagged on a photo; mentions on stories.
- A post can be sent into a chat (the paper plane), its link copied or shared.
- Stories: the ones seen turn grey and move to the end, the picture at the top opens the person's profile.
- Reels: the creator's profile, the comments and the post open with a "Reels" back button and the video plays on; on newer iPhones the close button and the controls keep clear of the notch.

Good to know:

- Instagram may slow down or restrict an account used from an unofficial client.
- Calls themselves are not possible: Instagram's calling is a closed system.
- The arm64 build (iOS 15 and newer: the rootless DEB and the TrollStore IPA) has not been tested on a device yet.

## 0.2.0 (2026-10-15)

The rework after the first day with a real account. Tested on an iPad 2 with iOS 6.1.3.

- The look of iOS 6 on every screen: dark linen, list rows with etched lines and the blue selection, glossy chat bubbles with tails, posts as the app looked in the iOS 6 days (a glossy header with the time, glossy Like and Comment buttons), glossy story rings, a profile with a framed picture and the counts in a glossy box, the name in script lettering. Every glyph is drawn: no emoji anywhere in the interface.
- A new icon: a camera lens on brushed graphite.
- Quicker: the first page of the feed, explore, activity, messages and reels is kept and shown at once on the next start while the network freshens it; the suggestions load alongside the timeline; replies are parsed off the main thread. (Most of the waiting is Instagram's server: 4 to 9 seconds for the timeline, explore and reels of a new account.)
- Stories: only people with a story to show (Instagram fills the tray of a new account with follow suggestions); video stories play.
- Reels: the real reels feed in a full-screen player, one video per screen, swiped up and down.
- Direct: voice messages play and show their progress; a tap on a picture or a name opens the profile; hearts and shared posts.
- Profiles: the real follow state (Following, Requested), a private account's follow request.
- Instagram's security check ("challenge required") can be passed in the app, with a code by e-mail or text message.
- Login through Instagram's current sign-in, with the password encrypted the way the app does it.

Good to know:

- A private build: not for redistribution.
- Instagram may slow down or restrict an account used from an unofficial client.
- The arm64 build (iOS 14-17: the rootless DEB and the TrollStore IPA) has not been tested on a device yet.

## 0.1.0 (2026-10-14)

First version: sign-in, feed, stories, profiles, likes, comments and direct messages, in English and Czech.
