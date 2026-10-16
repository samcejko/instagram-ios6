# Third-party notices

Gramify is an independent, unofficial client. It is not affiliated with, endorsed by or associated with Instagram or
Meta Platforms. Instagram is a trademark of Meta Platforms, Inc. The app signs in with your own account and talks to
the service the way its Android app does; using an unofficial client may be against the service's terms of use and can
get an account checked or locked, which is the user's call.

## On the device (the app)

- **Mbed TLS** - Apache License 2.0. The TLS 1.2 client for every HTTPS request (iOS 6's own stack cannot talk to
  modern servers), and the RSA and AES-GCM the sign-in encrypts the password with. https://github.com/Mbed-TLS/mbedtls
- **Mozilla CA certificate bundle** (curl.se/ca) - MPL-2.0. The roots TLS connections are checked against.
- **Theos** - the build system; not shipped in the app.

How the mobile interface works was learned from **instagrapi** (MIT, https://github.com/subzeroid/instagrapi); no
code of it is included.

The license texts of the shipped libraries are included in the app bundle (Settings).
