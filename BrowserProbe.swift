import SwiftUI
import WebKit
import UIKit
import CryptoKit

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
            let signingFailures = NativeSigningCore.selfTestFailures()
            report += signingFailures.isEmpty ? "Offline SM3/MD5/Gorgon checks: passed. Full native request signing is not implemented yet.\n" : "Offline signing checks failed; native requests disabled.\n"
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

// BEGIN NATIVE SIGNING CORE
// Experimental offline primitives; signature generation is not proof of API access.
// Gorgon compatibility reference: iqbalmh18/tiktok-signer, commit c981a8b.
// MIT License — Copyright (c) 2026 iqbalmh18
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
enum NativeSigningCore {
    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    static func md5(_ text: String) -> [UInt8] { Array(Insecure.MD5.hash(data: Data(text.utf8))) }
    static func rotate(_ x: UInt32, _ n: Int) -> UInt32 {
        let amount = n % 32
        return amount == 0 ? x : (x << amount) | (x >> (32 - amount))
    }
    static func sm3(_ input: [UInt8]) -> [UInt8] {
        var bytes = input
        let bitLength = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for n in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: bitLength >> n)) }
        var state: [UInt32] = [0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600,
                               0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e]
        for base in stride(from: 0, to: bytes.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 68)
            for i in 0..<16 {
                let p = base + 4*i
                w[i] = UInt32(bytes[p]) << 24 | UInt32(bytes[p+1]) << 16 | UInt32(bytes[p+2]) << 8 | UInt32(bytes[p+3])
            }
            for i in 16..<68 {
                let x = w[i-16] ^ w[i-9] ^ rotate(w[i-3], 15)
                w[i] = x ^ rotate(x, 15) ^ rotate(x, 23) ^ rotate(w[i-13], 7) ^ w[i-6]
            }
            var a=state[0], b=state[1], c=state[2], d=state[3]
            var e=state[4], f=state[5], g=state[6], h=state[7]
            for j in 0..<64 {
                let t: UInt32 = j < 16 ? 0x79cc4519 : 0x7a879d8a
                let ss1 = rotate(rotate(a, 12) &+ e &+ rotate(t, j), 7)
                let ss2 = ss1 ^ rotate(a, 12)
                let ff = j < 16 ? a ^ b ^ c : (a & b) | (a & c) | (b & c)
                let gg = j < 16 ? e ^ f ^ g : (e & f) | (~e & g)
                let tt1 = ff &+ d &+ ss2 &+ (w[j] ^ w[j+4])
                let tt2 = gg &+ h &+ ss1 &+ w[j]
                d=c; c=rotate(b,9); b=a; a=tt1
                h=g; g=rotate(f,19); f=e; e=tt2 ^ rotate(tt2,9) ^ rotate(tt2,17)
            }
            let next = [a,b,c,d,e,f,g,h]
            for i in 0..<8 { state[i] ^= next[i] }
        }
        return state.flatMap { word in [24,16,8,0].map { UInt8(truncatingIfNeeded: word >> $0) } }
    }
    static func gorgon(query: String, cookie: String?, timestamp: UInt32) -> String {
        let key = [30,64,224,217,147,69,0,180]
        var table = Array(0..<256)
        var last: Int?
        for i in 0..<256 {
            var a = i == 0 ? 0 : ((last ?? 0) != 0 ? last! : table[i-1])
            if a == 85 && i != 1 && last != 85 { a=0 }
            let c = (a + i + key[i%8]) % 256
            last = c < i ? c : nil
            table[i] = table[c]
        }
        var input = Array(md5(query).prefix(4)).map(Int.init) + [0,0,0,0]
        input += cookie.map { Array(md5($0).prefix(4)).map(Int.init) } ?? [0,0,0,0]
        input += [0,0,0,0]
        input += [24,16,8,0].map { Int(UInt8(truncatingIfNeeded: timestamp >> $0)) }
        var temporary = table, previous=0
        for i in 0..<20 {
            let c=(table[i+1]+previous)%256
            previous=c
            let d=temporary[c]
            temporary[i+1]=d
            input[i] ^= temporary[(d+d)%256]
        }
        for i in 0..<20 {
            let swapped=((input[i]&15)<<4)|(input[i]>>4)
            let x=swapped ^ input[(i+1)%20]
            var reversed=0
            for bit in 0..<8 { reversed |= ((x>>bit)&1) << (7-bit) }
            input[i] = (~(reversed ^ 20)) & 255
        }
        return "8404b4d94000" + hex(input.map(UInt8.init))
    }
    static func selfTestFailures() -> [String] {
        var failures: [String] = []
        if hex(md5("abc")) != "900150983cd24fb0d6963f7d28e17f72" { failures.append("MD5 standard vector") }
        if hex(sm3(Array("abc".utf8))) != "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0" { failures.append("SM3 standard vector") }
        // More vectors are inserted from an independent OpenSSL implementation by the build preparer.
        // BEGIN REFERENCE VECTORS
        if hex(sm3([])) != "1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b" { failures.append("SM3 OpenSSL vector 0") }
        if hex(sm3([97,98,99])) != "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0" { failures.append("SM3 OpenSSL vector 1") }
        if hex(sm3([97,98,99,100,97,98,99,100,97,98,99,100,97,98,99,100,97,98,99,100,97,98,99,100,97,98,99,100,97,98,99,100,97,98,99,100,97,98,99,100,97,98,99,100,97,98,99,100,97,98,99,100,97,98,99,100,97,98,99,100,97,98,99,100])) != "debe9ff92275b8a138604889c18e5a4d6fdb70e5387e5765293dcba39c0c5732" { failures.append("SM3 OpenSSL vector 2") }
        if hex(sm3([120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120])) != "ff8f8d58b95a1f90e39d96f739fa873eee33c0a80e59c7bbbf184eb7d9b1f112" { failures.append("SM3 OpenSSL vector 3") }
        if hex(sm3([120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120])) != "c4c1c6206d36c325e66ae5432948b26f04acff8dfc0ea2606a79d59b83a16d61" { failures.append("SM3 OpenSSL vector 4") }
        if hex(sm3([120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120,120])) != "063cfef4083326d61866e4bc3283fca4823f4f771d82a95b76a668454bfb0d24" { failures.append("SM3 OpenSSL vector 5") }
        if gorgon(query: "aid=1233&cursor=0&count=20", cookie: nil, timestamp: 1700000000) != "8404b4d9400080395c76cf0918c5fbeac413362c8dbaebdbc250" { failures.append("Gorgon reference vector 0") }
        if gorgon(query: "aid=1233&cursor=0&count=20", cookie: "sessionid=TEST_ONLY", timestamp: 1700000000) != "8404b4d9400080395c76cf0918feee64538e362c8dbaebdbc250" { failures.append("Gorgon reference vector 1") }
        if gorgon(query: "", cookie: nil, timestamp: 1700000000) != "8404b4d94000c383773acf0918c5fbeac413362c8dbaebdbc292" { failures.append("Gorgon reference vector 2") }
        // END REFERENCE VECTORS
        return failures
    }
}
// END NATIVE SIGNING CORE
