import SwiftUI
import WebKit
import UIKit

final class NoRedirectProbe: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@main
struct BrowserProbeApp: App {
    var body: some Scene { WindowGroup { ProbeScreen() } }
}

final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var status = "Open TikTok and sign in, then try Messages."
    @Published var address = ""
    @Published var desktop = true
    @Published var testingSaved = false
    @Published var savedReport = ""
    @Published var showingReport = false
    let web: WKWebView
    private var diagnosticGeneration = 0
    private let desktopAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
    private let directReadScript = #"""
    (async () => {
      // Never invoke unknown SDK functions. Inspect names/code only, and issue GETs only.
      const result = {version: 3, signedIn: false, sdkFound: false, readMethods: [],
        sendMethods: [], stickerCodeHint: false, webRequests: []};
      try {
        const scope = JSON.parse(document.getElementById('__UNIVERSAL_DATA_FOR_REHYDRATION__')?.textContent || '{}').__DEFAULT_SCOPE__;
        result.signedIn = !!scope?.['webapp.app-context']?.user?.uid;
      } catch (_) {}
      const root = document.querySelector('[data-e2e="dm-new-chatbox"]');
      let fiber = root?.[Object.keys(root).find(k => k.startsWith('__reactFiber'))], instance;
      for (let depth = 0; fiber && depth < 80; depth++, fiber = fiber.return) {
        const p = fiber.memoizedProps;
        if (p?.instance) instance = p.instance;
        if (p?.value?.instance) instance = p.value.instance;
      }
      if (instance) {
        result.sdkFound = true;
        const names = new Set();
        for (let p = instance, d = 0; p && d < 8; p = Object.getPrototypeOf(p), d++) {
          for (const name of Object.getOwnPropertyNames(p)) {
            const descriptor = Object.getOwnPropertyDescriptor(p, name);
            if (typeof descriptor?.value !== 'function') continue;
            names.add(name);
            if (/send|createMessage/i.test(name) && /sticker|sticker_card/i.test(String(descriptor.value))) result.stickerCodeHint = true;
          }
        }
        result.readMethods = [...names].filter(n => /sticker|favorite|favourite/i.test(n) && /^(get|fetch|list|load|pull)/i.test(n)).slice(0,30);
        result.sendMethods = [...names].filter(n => /^(sendMessage|createMessage|sendSticker|send.*Sticker)$/i.test(n)).slice(0,15);
      }
      if (!result.signedIn) return JSON.stringify(result);
      const paths = ['/tiktok/v1/im/sticker/favorites', '/tiktok/v2/im/sticker/favorites', '/api/im/sticker/favorites/'];
      result.webRequests = await Promise.all(paths.map(async path => {
        const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 7000);
        try {
          const response = await fetch(path + '?cursor=0&count=20&in_house_tenor=true&source=dm',
            {method:'GET', credentials:'include', redirect:'error', signal:controller.signal});
          const body = await response.text();
          let json; try { if (body.length < 2000000) json = JSON.parse(body); } catch (_) {}
          const stickers = json?.stickers ?? json?.data?.stickers;
          return {path, http:response.status, json:!!json, stickerArray:Array.isArray(stickers),
            stickerCount:Array.isArray(stickers)?stickers.length:0,
            statusCode:typeof json?.status_code==='number'?json.status_code:null};
        } catch (error) { return {path, error:error.name==='AbortError'?'timeout':'request unavailable'}; }
        finally { clearTimeout(timer); }
      }));
      return JSON.stringify(result);
    })()
    """#

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        config.userContentController.addUserScript(WKUserScript(source: """
        (() => {
          if (!navigator.userAgent.includes('Windows NT')) return;
          let meta = document.querySelector('meta[name="viewport"]');
          if (!meta) {
            meta = document.createElement('meta');
            meta.name = 'viewport';
            document.head.appendChild(meta);
          }
          meta.content = 'width=1280, initial-scale=0.25, user-scalable=yes';
        })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        web.customUserAgent = desktopAgent
        web.allowsBackForwardNavigationGestures = true
        web.isOpaque = true
        web.backgroundColor = UIColor(red: 0.05, green: 0.08, blue: 0.13, alpha: 1)
        load("https://www.tiktok.com/")
    }

    private func trusted(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "tiktok.com" || host.hasSuffix(".tiktok.com")
    }

    func load(_ value: String) {
        guard let url = URL(string: value), trusted(url) else { return }
        status = "Loading TikTok…"
        web.load(URLRequest(url: url))
    }

    func applyMode() {
        diagnosticGeneration += 1
        web.customUserAgent = desktop ? desktopAgent : nil
        web.configuration.defaultWebpagePreferences.preferredContentMode = desktop ? .desktop : .mobile
        load("https://www.tiktok.com/messages?lang=en")
    }

    func checkChat() {
        diagnosticGeneration += 1
        inspect(generation: diagnosticGeneration, remaining: 10)
    }

    func testSaved() {
        guard !testingSaved, let page = web.url, trusted(page) else { return }
        diagnosticGeneration += 1
        testingSaved = true
        status = "Testing Saved access on this iPhone. No messages will be sent."
        savedReport = ""
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            var report = "IPHONE DIRECT SAVED TEST v3\nRead-only; no messages sent.\n"
            do {
                let value = try await self.web.callAsyncJavaScript("return await " + self.directReadScript,
                    arguments: [:], in: nil, in: .page)
                if let json = value as? String { report += "Web client: \(json)\n" }
                else { report += "Web client: no diagnostic result\n" }
            } catch { report += "Web client: inspection unavailable\n" }
            let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
                self.web.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
            }
            let allowed = Set(["sessionid", "sessionid_ss", "sid_tt", "sid_guard", "store-idc", "store-country-code", "store-country-code-src", "ttwid"])
            let selected = cookies.filter {
                let host = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                return (host == "tiktok.com" || host.hasSuffix(".tiktok.com")) && allowed.contains($0.name)
            }
            let hasSession = selected.contains { ["sessionid", "sessionid_ss", "sid_tt"].contains($0.name) }
            if hasSession {
                // Reuse only this app's TikTok session in memory, only with these TikTok API hosts.
                // Do not follow redirects or put credentials, response bodies, media URLs or IDs in reports.
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil
                config.urlCredentialStorage = nil
                config.timeoutIntervalForRequest = 7
                config.timeoutIntervalForResource = 9
                let session = URLSession(configuration: config, delegate: NoRedirectProbe(), delegateQueue: nil)
                let cookieHeader = selected.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                let hosts = ["api.tiktokv.com", "api-va.tiktokv.com", "api16-normal-c-useast1a.tiktokv.com"]
                let nativeResults = await withTaskGroup(of: String.self, returning: [String].self) { group in
                    for host in hosts {
                        group.addTask {
                            var lines: [String] = []
                            for version in ["v1", "v2"] {
                                let path = "/tiktok/\(version)/im/sticker/favorites"
                                let url = URL(string: "https://\(host)\(path)?aid=1233&cursor=0&count=20&in_house_tenor=true&source=dm")!
                                var request = URLRequest(url: url)
                                request.httpMethod = "GET"
                                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
                                request.setValue(self.desktopAgent, forHTTPHeaderField: "User-Agent")
                                do {
                                    let (data, response) = try await session.data(for: request)
                                    let http = (response as? HTTPURLResponse)?.statusCode ?? 0
                                    let json = data.count < 2000000 ? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] : nil
                                    let nested = json?["data"] as? [String: Any]
                                    let stickers = (json?["stickers"] ?? nested?["stickers"]) as? [Any]
                                    let code = (json?["status_code"] as? NSNumber)?.stringValue ?? "unavailable"
                                    lines.append("\(host) \(version): HTTP \(http), JSON \(json != nil), stickerArray \(stickers != nil), count \(stickers?.count ?? 0), status \(code)")
                                } catch { lines.append("\(host) \(version): request unavailable or timed out") }
                            }
                            return lines.joined(separator: "\n")
                        }
                    }
                    var values: [String] = []
                    for await value in group { values.append(value) }
                    return values.sorted()
                }
                session.invalidateAndCancel()
                report += nativeResults.joined(separator: "\n")
            } else { report += "Native API: no signed-in TikTok session available in this app." }
            self.savedReport = report
            self.testingSaved = false
            self.status = "Saved test finished. Open the report; results do not yet prove transfer support."
            self.showingReport = true
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, trusted(url) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame != false && !trusted(url) {
            status = "TikTok tried to open an external page. This probe keeps you on TikTok."
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        diagnosticGeneration += 1
        status = "Loading TikTok…"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // No cookies, credentials, account identifiers or message contents are collected.
        guard let url = webView.url, trusted(url) else { return }
        address = url.path.isEmpty ? "/" : url.path
        diagnosticGeneration += 1
        let generation = diagnosticGeneration
        inspect(generation: generation, remaining: 10)
    }

    private func inspect(generation: Int, remaining: Int) {
        let script = """
        (() => {
          let signedIn = false;
          try {
            const el = document.getElementById('__UNIVERSAL_DATA_FOR_REHYDRATION__');
            const user = el ? JSON.parse(el.textContent).__DEFAULT_SCOPE__?.['webapp.app-context']?.user : null;
            signedIn = !!user?.uid;
          } catch (_) {}
          return {path: location.pathname,
            conversations: !!document.querySelector('[data-e2e="dm-new-conversation-list"]'),
            chat: (() => {
              const header = document.querySelector('[data-e2e="dm-new-chatbox"] [class*="DivChatHeader"]');
              return !!header && !!header.textContent.trim();
            })(),
            signedIn: signedIn};
        })()
        """
        web.evaluateJavaScript(script) { [weak self] value, error in
            guard let self = self, generation == self.diagnosticGeneration else { return }
            guard let result = value as? [String: Any] else {
                self.status = "Page inspection unavailable. Check the visible page."
                return
            }
            let path = result["path"] as? String ?? "/"
            let messages = result["conversations"] as? Bool ?? false
            let chat = result["chat"] as? Bool ?? false
            let signedIn = result["signedIn"] as? Bool ?? false
            self.address = path
            if chat {
                self.status = "Conversation opened. Web chat works; Saved sticker retrieval is still unverified."
            } else if messages {
                self.status = "Messages loaded. Tap a conversation; pinch to zoom or swipe across the wide page, then tap Check chat."
            } else if remaining > 0 {
                self.status = "Waiting for TikTok’s page to finish loading…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.inspect(generation: generation, remaining: remaining - 1)
                }
            } else {
                self.status = "Messages list not detected. Current page: \(path). Login detected: \(signedIn ? "yes" : "no or unavailable")."
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { status = "TikTok failed to load. Check your connection and try again." }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        status = "TikTok’s page failed to load. Try again."
    }
}

struct BrowserSurface: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct ProbeScreen: View {
    @StateObject private var model = BrowserModel()
    private let mint = Color(red: 0.39, green: 0.89, blue: 0.75)
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("STICKER SYNC · IPHONE WEB TEST").font(.caption).tracking(2).foregroundColor(mint)
            Toggle("Desktop browser identity", isOn: $model.desktop).tint(mint)
                .onChange(of: model.desktop) { _ in model.applyMode() }
            HStack {
                Button("Sign in") { model.load("https://www.tiktok.com/login/phone-or-email/email") }
                Button("Messages") { model.load("https://www.tiktok.com/messages?lang=en") }
                Button("Reload") { model.web.reload() }
            }.buttonStyle(.bordered).tint(mint)
            Button("Check chat") { model.checkChat() }.buttonStyle(.bordered).tint(mint)
            Button(model.testingSaved ? "Testing Saved…" : "Test Saved access") { model.testSaved() }
                .buttonStyle(.bordered).tint(mint).disabled(model.testingSaved)
            Text(model.status).font(.footnote).foregroundColor(.white).accessibilityLabel(model.status)
            BrowserSurface(web: model.web).clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .padding(16)
        .background(Color(red: 0.05, green: 0.08, blue: 0.13).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showingReport) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Saved access test").font(.title2)
                ScrollView { Text(model.savedReport).font(.system(.footnote, design: .monospaced)).textSelection(.enabled) }
                HStack {
                    Button("Copy report") { UIPasteboard.general.string = model.savedReport }
                    Button("Done") { model.showingReport = false }
                }.buttonStyle(.bordered)
            }.padding()
        }
    }
}
