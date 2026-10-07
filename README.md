# iPhone TikTok browser feasibility probe

This is a diagnostic source app, not the finished Sticker Sync iPhone port. The included GitHub Actions workflow builds an unsigned device IPA without Apple credentials. Compilation and device validation are pending until that workflow is run. The current development machine is Windows.

The user's iPhone 7 redirects `/messages` to TikTok's home page in Safari and Chrome, with or without login, after requesting the desktop site. This probe tests a narrower remaining possibility: a WKWebView using the exact explicit desktop Chrome user-agent employed by the working Android browser, combined with Apple's desktop content preference. The switch permits a mobile-mode comparison. It lets TikTok perform redirects normally; cancelling the redirect would not create the missing Messages page. It cannot force TikTok's server to provide unavailable content or add native Saved stickers to a web page.

## Build when a macOS builder is available

1. Open `BrowserProbe.xcodeproj` in Xcode. The shared BrowserProbe scheme targets iPhone with iOS 15.0 or later. No third-party packages are required.
2. Select an authorized signing team and a connected iPhone, then build and run. Alternatively, run the GitHub Actions workflow and download its unsigned IPA. That IPA still needs local Apple signing before installation; compilation alone does not authorize a phone to run it.
3. Leave Desktop browser identity enabled, choose Sign in, complete login and verification yourself, then choose Messages. Observe the status and visible page. Switch desktop mode off for comparison.

The workflow uses the standard `macos-14` runner, a fifteen-minute timeout, manual dispatch only, read-only repository permissions, and one-day artifact retention. It contains no Apple credentials or cloud secrets. Standard GitHub-hosted runners are free for public repositories. Free Apple provisioning normally expires after seven days, so this development test may need refreshing. Installation through Windows tooling is a separate user-authorized step.

Login uses TikTok's own HTTPS page and WKWebView's app-local website data store. The optional Test Saved access action makes only same-origin read-only GET requests and inspects web SDK/API method names without invoking them. There is no companion server. Cookies, passwords, account identifiers, message contents, media URLs and raw response bodies are excluded from the copyable diagnostic report and from the public repository. TLS validation remains enabled. TikTok HTTPS popup links open in the same browser; external providers remain outside this probe.

Even success means only Messages web access is available. Android still obtains Saved stickers by native automation, sending them to the user's self-chat, then reading originals through the web messaging client. A regular iPhone app needs another verified retrieval mechanism to reproduce that experience without additional manual steps. The Android Node and Rust native runtime binaries also cannot be reused directly as iOS binaries. No claim of identical iPhone functionality or working scheduled transfers is made.

## References

- https://developer.apple.com/documentation/webkit/wkwebview/customuseragent
- https://developer.apple.com/documentation/webkit/wkwebpagepreferences/preferredcontentmode
- https://developer.apple.com/xcode/system-requirements
- https://support.apple.com/en-au/guide/security/sec15bfe098e/web

The user installed the probe on an iPhone 7 running iOS 15.8.8. They confirmed desktop-mode chats display stickers but only offer emoji sending, while mobile mode does not show Messages. The v3 native test returned HTTP 403 without JSON for all six requests across three TikTok hosts and two route versions. Its web-client result was missing. Revision v4 replaces the asynchronous return bridge with a bounded synchronous string-result poll, inspects SDK and API method names, and checks website GET routes. It does not repeat the rejected native requests or implement native request signing. Web-test results are pending. Method names alone do not prove sticker sending, and an empty sticker array does not prove access to the user's Saved library.

The user's v4 report confirms signed-in web execution. They ran it from the conversation list, explaining the absent chat root and messaging SDK. Two website variants were unavailable; `/api/im/sticker/favorites/` returned HTTP 200 JSON with status code 0 but no expected sticker array. Revision v5 reports an allowlisted field/type-only response schema (never leaf values), compares against a deliberately nonexistent API route to identify generic success fallbacks, and searches additional chat DOM markers. It must be run with the self-chat open. Direct Saved access is still unproved.

The user's v5 self-chat report confirms that the SDK is reachable and exposes `createMessage`, `sendMessage`, and `SendMessage`. Its favourite methods concern conversations, not sticker favourites. The tested web Saved path and nonexistent control have the same empty success schema (`log_pb`, `status_code`, `status_msg`), so neither response establishes Saved access. Static inspection of the Android sticker API factory also found both `tiktok/v1/` and `tiktok/v2/` prefixes, consistent with the native paths tested. All tested native requests rejected the reused web login with HTTP 403; the rejection's exact cause remains unknown. A functioning native-authenticated/signed Saved request has not been reproduced. No stickers were sent by these probes, and there is no demonstrated automatic, server-free iPhone transfer mechanism.
