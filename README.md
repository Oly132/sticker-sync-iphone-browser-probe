# iPhone TikTok browser feasibility probe

This is a diagnostic source app, not the finished Sticker Sync iPhone port. The included GitHub Actions workflow builds an unsigned device IPA without Apple credentials. Compilation and device validation are pending until that workflow is run. The current development machine is Windows.

The user's iPhone 7 redirects `/messages` to TikTok's home page in Safari and Chrome, with or without login, after requesting the desktop site. This probe tests a narrower remaining possibility: a WKWebView using the exact explicit desktop Chrome user-agent employed by the working Android browser, combined with Apple's desktop content preference. The switch permits a mobile-mode comparison. It lets TikTok perform redirects normally; cancelling the redirect would not create the missing Messages page. It cannot force TikTok's server to provide unavailable content or add native Saved stickers to a web page.

## Build when a macOS builder is available

1. Open `BrowserProbe.xcodeproj` in Xcode. The shared BrowserProbe scheme targets iPhone with iOS 15.0 or later. No third-party packages are required.
2. Select an authorized signing team and a connected iPhone, then build and run. Alternatively, run the GitHub Actions workflow and download its unsigned IPA. That IPA still needs local Apple signing before installation; compilation alone does not authorize a phone to run it.
3. Leave Desktop browser identity enabled, choose Sign in, complete login and verification yourself, then choose Messages. Observe the status and visible page. Switch desktop mode off for comparison.

The workflow uses the standard `macos-14` runner, a fifteen-minute timeout, manual dispatch only, read-only repository permissions, and one-day artifact retention. It contains no Apple credentials or cloud secrets. Standard GitHub-hosted runners are free for public repositories. Free Apple provisioning normally expires after seven days, so this development test may need refreshing. Installation through Windows tooling is a separate user-authorized step.

The code deliberately does not read cookies, record passwords, send account details to a server, copy chat contents or export messages. Login uses TikTok's own HTTPS page and WKWebView's app-local website data store. Main-frame navigation is limited to TikTok's HTTPS domains; external-login providers and popups are not supported by this focused probe. TLS validation remains enabled.

Even success means only Messages web access is available. Android still obtains Saved stickers by native automation, sending them to the user's self-chat, then reading originals through the web messaging client. A regular iPhone app needs another verified retrieval mechanism to reproduce that experience without additional manual steps. The Android Node and Rust native runtime binaries also cannot be reused directly as iOS binaries. No claim of identical iPhone functionality or working scheduled transfers is made.

## References

- https://developer.apple.com/documentation/webkit/wkwebview/customuseragent
- https://developer.apple.com/documentation/webkit/wkwebpagepreferences/preferredcontentmode
- https://developer.apple.com/xcode/system-requirements
- https://support.apple.com/en-au/guide/security/sec15bfe098e/web

Swift source is prepared for review. Compilation and device validation are pending.
