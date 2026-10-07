import SwiftUI
import WebKit
import UIKit

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
      const result = {version: 5, signedIn: false, chatRoot: false, sdkFound: false, readMethods: [],
        sendMethods: [], apiMethods: [], stickerCodeHint: false, webRequests: [], domMarkers: []};
      const schemaKeys = new Set(['status_code','status_msg','message','data','stickers','sticker_list','favorite_stickers',
        'favorites','list','items','cursor','has_more','hasMore','log_pb','extra','code','success','url_list','url',
        'sticker','sticker_card','sticker_infos','total','count','image','image_url','video','id','type','sticker_id',
        'sticker_type','user_sticker_list','favorite_sticker_list','aweme_list','collect_list','status','error','detail']);
      function shape(value, depth=0) {
        if (value === null) return 'null';
        if (depth > 5) return Array.isArray(value)?'array':typeof value;
        if (Array.isArray(value)) return {arrayLength:value.length, item:value.length?shape(value[0],depth+1):null};
        if (typeof value === 'object') {
          const out = {}, keys = Object.keys(value);
          for (const key of keys.filter(k=>schemaKeys.has(k)).slice(0,30)) out[key]=shape(value[key],depth+1);
          const omitted = keys.filter(k=>!schemaKeys.has(k)).length;
          if (omitted) out.otherFieldCount = omitted;
          return out;
        }
        return typeof value;
      }
      try {
        const scope = JSON.parse(document.getElementById('__UNIVERSAL_DATA_FOR_REHYDRATION__')?.textContent || '{}').__DEFAULT_SCOPE__;
        result.signedIn = !!scope?.['webapp.app-context']?.user?.uid;
      } catch (_) {}
      const root = document.querySelector('[data-e2e="dm-new-chatbox"]');
      result.chatRoot = !!root;
      const marked = Array.from(document.querySelectorAll('[data-e2e]'));
      result.domMarkers = [...new Set(marked.map(e=>e.getAttribute('data-e2e'))
        .filter(n=>/^(dm|im|chat|message|conversation|sticker|emoji)[-_a-z0-9]{0,80}$/i.test(n)))].slice(0,40);
      const candidates = [root, ...marked.filter(e=>/chat|message|conversation|sticker/i.test(e.getAttribute('data-e2e')||'')),
        ...Array.from(document.querySelectorAll('[class*="Chat"],[class*="Message"],[class*="Conversation"]'))].filter(Boolean).slice(0,100);
      let instance;
      const visited = new Set();
      for (const element of candidates) {
        let fiber = element[Object.keys(element).find(k=>k.startsWith('__reactFiber'))];
        for (let depth = 0; fiber && depth < 80; depth++, fiber = fiber.return) {
          if (visited.has(fiber)) break;
          visited.add(fiber);
          const p = fiber.memoizedProps;
          const candidate = p?.instance || p?.value?.instance;
          if (candidate && typeof candidate.getConversation === 'function') { instance = candidate; break; }
        }
        if (instance) break;
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
        // API containers may expose functions absent from the SDK instance itself.
        const containers = [instance.api, ...(Array.isArray(instance.plugins) ? instance.plugins.map(p => p?.api) : [])];
        const apiNames = new Set();
        for (const container of containers) {
          for (let p = container, d = 0; p && d < 4; p = Object.getPrototypeOf(p), d++) {
            for (const name of Object.getOwnPropertyNames(p)) {
              const descriptor = Object.getOwnPropertyDescriptor(p, name);
              if (typeof descriptor?.value === 'function' && /sticker|favorite|favourite|sendMessage/i.test(name)) apiNames.add(name);
            }
          }
        }
        result.apiMethods = [...apiNames].slice(0,40);
      }
      if (!result.signedIn) return JSON.stringify(result);
      // A known-nonexistent control distinguishes generic HTTP-200 JSON fallback
      // from a working API. Never treat status_code:0 alone as Saved access.
      const paths = ['/tiktok/v1/im/sticker/favorites', '/tiktok/v2/im/sticker/favorites', '/api/im/sticker/favorites/', '/api/stickersync_probe_missing_route/'];
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
            schema:json?shape(json):null,
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
            var report = "IPHONE WEB SAVED TEST v5\nRead-only; no messages sent.\n"
            do {
                // Read the result through a synchronous string bridge. Do not rely on
                // iOS 15's conversion of an asynchronously returned JavaScript value.
                let token = UUID().uuidString
                let tokenJSON = "\"\(token)\""
                let launch = """
                (() => {
                  const token = \(tokenJSON);
                  window.__stickerSavedDiagnostic = {token, result:null};
                  \(self.directReadScript).then(result => {
                    if (window.__stickerSavedDiagnostic?.token === token) window.__stickerSavedDiagnostic.result = result;
                  }).catch(() => {
                    if (window.__stickerSavedDiagnostic?.token === token) window.__stickerSavedDiagnostic.result = JSON.stringify({version:5,error:'web inspection failed'});
                  });
                  return 'started';
                })()
                """
                _ = try await self.web.evaluateJavaScript(launch)
                var webResult: String?
                for _ in 0..<24 {
                    let value = try await self.web.evaluateJavaScript("window.__stickerSavedDiagnostic?.token === \(tokenJSON) ? window.__stickerSavedDiagnostic.result : null")
                    if let json = value as? String { webResult = json; break }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                if let json = webResult { report += "Web client: \(json)\n" }
                else { report += "Web client: timed out or page changed; keep the self-chat open during the test.\n" }
                _ = try? await self.web.evaluateJavaScript("if (window.__stickerSavedDiagnostic?.token === \(tokenJSON)) delete window.__stickerSavedDiagnostic; true")
            } catch { report += "Web client: inspection unavailable (WebKit error \((error as NSError).code))\n" }
            // The authenticated iPhone v3 test already rejected every native route
            // with HTTP 403. Do not repeat those requests in this web-only test.
            self.savedReport = report + "Native API: prior iPhone test rejected all six routes with HTTP 403. Not repeated."
            self.testingSaved = false
            self.status = "Web Saved test finished. Open the diagnostic report."
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
            Button(model.testingSaved ? "Testing Saved…" : "Test Saved access · v4") { model.testSaved() }
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
