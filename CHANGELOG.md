# Changelog

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
