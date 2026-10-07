import SwiftUI
import WebKit
import UIKit
import CryptoKit
import CommonCrypto

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
    static func ror64(_ x: UInt64, _ n: Int) -> UInt64 { (x >> n) | (x << (64-n)) }
    static func littleWord(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset+$1]) << ($1*8) }
    }
    static func littleBytes(_ x: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: x >> ($0*8)) } }
    static func pad(_ bytes: [UInt8]) -> [UInt8] {
        let count = 16 - bytes.count % 16
        return bytes + [UInt8](repeating: UInt8(count), count: count)
    }
    static func ladon(timestamp: UInt32, salt: [UInt8]) -> String {
        precondition(salt.count == 4)
        let digest = hex(Array(Insecure.MD5.hash(data: Data(salt + Array("1233".utf8)))))
        let material = Array(digest.utf8)
        var previous=littleWord(material,0), queue=[littleWord(material,8),littleWord(material,16),littleWord(material,24)]
        var keys=[previous]
        for i in 0..<33 {
            let next=(ror64(queue.removeFirst(),8) &+ previous) ^ UInt64(i)
            queue.append(next)
            previous=next ^ ror64(previous,61)
            keys.append(previous)
        }
        let input=pad(Array("\(timestamp)-2142840551-1233".utf8))
        var output=salt
        for offset in stride(from:0,to:input.count,by:16) {
            var a=littleWord(input,offset), b=littleWord(input,offset+8)
            for key in keys { b=key ^ (a &+ ror64(b,8)); a=b ^ ror64(a,61) }
            output += littleBytes(a) + littleBytes(b)
        }
        return Data(output).base64EncodedString()
    }
    static func simon(_ input: [UInt8], key: [UInt8]) -> [UInt8] {
        precondition(input.count % 16 == 0 && key.count == 32)
        var keys=(0..<4).map { littleWord(key,$0*8) }
        let constant: UInt64 = 0x3dc94c3a046d678b
        for i in 4..<72 {
            var t=ror64(keys[i-1],3) ^ keys[i-3]
            t ^= ror64(t,1)
            keys.append(~keys[i-4] ^ t ^ ((constant >> ((i-4)%62)) & 1) ^ 3)
        }
        var output: [UInt8]=[]
        for offset in stride(from:0,to:input.count,by:16) {
            var a=littleWord(input,offset), b=littleWord(input,offset+8)
            for key in keys {
                let next=a ^ (ror64(b,63) & ror64(b,56)) ^ ror64(b,62) ^ key
                a=b; b=next
            }
            output += littleBytes(a) + littleBytes(b)
        }
        return output
    }
    struct PB {
        var bytes: [UInt8]=[]
        mutating func rawVarint(_ input: UInt64) {
            var value=input
            while value>=128 { bytes.append(UInt8(value & 127)|128); value >>= 7 }
            bytes.append(UInt8(value))
        }
        mutating func integer(_ field: UInt64,_ value: UInt64) { rawVarint(field<<3); rawVarint(value) }
        mutating func data(_ field: UInt64,_ value: [UInt8]) { rawVarint((field<<3)|2); rawVarint(UInt64(value.count)); bytes += value }
        mutating func text(_ field: UInt64,_ value: String) { data(field,Array(value.utf8)) }
    }
    enum SigningError: Error { case aesFailed }
    static func aesCBC(_ input: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        guard key.count == 16 && iv.count == 16 else { throw SigningError.aesFailed }
        var output=[UInt8](repeating:0,count:input.count+16), written=0
        let capacity=output.count
        let result = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in input.withUnsafeBytes { p in output.withUnsafeMutableBytes { out in
            CCCrypt(CCOperation(kCCEncrypt),CCAlgorithm(kCCAlgorithmAES),CCOptions(kCCOptionPKCS7Padding),
                    k.baseAddress,key.count,v.baseAddress,p.baseAddress,input.count,out.baseAddress,capacity,&written)
        }}}}
        guard result == kCCSuccess else { throw SigningError.aesFailed }
        return Array(output.prefix(written))
    }
    static func argus(query: String, deviceID: String, timestamp: UInt32, nonce: UInt32) throws -> String {
        var pb=PB()
        pb.integer(1,0x20200929<<1); pb.integer(2,2); pb.integer(3,UInt64(nonce))
        pb.text(4,"1233"); pb.text(5,deviceID); pb.text(6,"2142840551")
        pb.text(7,"v05.01.02-alpha.7-ov-android"); pb.text(8,"v05.01.02-alpha.7-ov-android")
        pb.integer(9,83952160); pb.data(10,[UInt8](repeating:0,count:8)); pb.text(11,"android")
        pb.integer(12,UInt64(timestamp)<<1); pb.data(13,Array(sm3([UInt8](repeating:0,count:16)).prefix(6)))
        pb.data(14,Array(sm3(query.isEmpty ? [UInt8](repeating:0,count:16) : Array(query.utf8)).prefix(6)))
        var counters=PB()
        for field in [UInt64(1),2,3,5,6] { counters.integer(field,field==6 ? 170 : 85) }
        counters.integer(7,(UInt64(timestamp)<<1)-310); pb.data(15,counters.bytes)
        pb.text(16,deviceID); pb.text(20,"none"); pb.integer(21,738)
        var device=PB()
        device.text(1,"2203121C"); device.text(2,"9"); device.text(3,"googleplay"); device.integer(4,0x01009400<<1)
        pb.data(23,device.bytes); pb.integer(25,2)
        let key: [UInt8] = [0xfc,0x78,0xe0,0xa9,0x65,0x7a,0x0c,0x74,0x8c,0xe5,0x15,0x59,0x90,0x3c,0xcf,0x03,0x51,0x0e,0x51,0xd3,0xcf,0xf2,0x32,0xd7,0x13,0x43,0xe8,0x8a,0x32,0x1c,0x53,0x04]
        let xor: [UInt8] = [0xf2,0xf7,0xfc,0xff,0xf2,0xf7,0xfc,0xff]
        var encoded = xor + simon(pad(pb.bytes),key:key)
        for i in 8..<encoded.count { encoded[i] ^= xor[i%8] }
        let buffer: [UInt8] = [0xa6,0x6e,0xad,0x9f,0x77,0x01,0xd0,0x0c,0x18] + Array(encoded.reversed()) + [0x61,0x6f]
        let signKey: [UInt8] = [0xac,0x1a,0xda,0xae,0x95,0xa7,0xaf,0x94,0xa5,0x11,0x4a,0xb3,0xb3,0xa9,0x7d,0xd8,0x00,0x50,0xaa,0x0a,0x39,0x31,0x4c,0x40,0x52,0x8c,0xae,0xc9,0x52,0x56,0xc2,0x8c]
        let aesKey=Array(Insecure.MD5.hash(data:Data(signKey.prefix(16))))
        let iv=Array(Insecure.MD5.hash(data:Data(signKey.suffix(16))))
        return Data([0xf2,0x81] + (try aesCBC(buffer,key:aesKey,iv:iv))).base64EncodedString()
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
        if ladon(timestamp: 1700000000, salt: [1, 2, 3, 4]) != "AQIDBAg9q7y2FKMM0eeGFk1n4W/Q28AxEuIoF+PlPOv0uX8J" { failures.append("Ladon cross-implementation vector 0") }
        if ladon(timestamp: 1700000011, salt: [1, 2, 3, 4]) != "AQIDBHORJ1wUm5sIC7JwffyEwZ/Q28AxEuIoF+PlPOv0uX8J" { failures.append("Ladon cross-implementation vector 1") }
        do { if try argus(query: "aid=1233&device_id=1234567890123456789&device_type=2203121C&os_version=9&channel=googleplay&version_name=37.0.4&cursor=0&count=20", deviceID: "1234567890123456789", timestamp: 1700000000, nonce: 12345) != "8oGq9ypdP1R0Yt46uZPVHJHqYFS0vSftUDt8DpMHZDglY9Iiysy8LMUU9iNg1u8DPGexO0LNLtdl7TSrbLLZ1TkJU4T1/BhqlkPDyDC82laua2mtBpq/ZE1NS4wClgAnRCS4ocWgLl6CXjfJBcndZoXuVvKh4qObIZk1bxbCrnoT/0d3yMMb6jH6D3+0n65X5LFCjc19oKlqr/7U1Yt61NW2ftm7Xu2v3iN9zr5eb3R1Bk+WKUJieuU4rUOnL2eSshf5B3WzKvwpeoNjGFih2Td3lJSWJ4S9qn8mDmAjOaKwJH7kIHUs9uai32E67nT7u54oOMTIZXGsRhgnucBTMQOkluPtrZlDtLHzWCywXmICqLfo6ztQGvqBVqzapB4S4Jc=" { failures.append("Argus compatibility vector 0") } } catch { failures.append("Argus AES failure") }
        do { if try argus(query: "aid=1233&device_id=1234567890123456789&device_type=2203121C&os_version=9&channel=googleplay&version_name=37.0.4&cursor=0&count=20", deviceID: "1234567890123456789", timestamp: 1700000011, nonce: 12345) != "8oGq9ypdP1R0Yt46uZPVHJHqYFS0vSftUDt8DpMHZDglY9Iiysy8LMUU9iNg1u8DPGexO0LNLtdl7TSrbLLZ1TkJU4T1/BhqlkPDyDC82laua4Jzt8nshHrvoWNFgblLMlFE3TrdnGjgi+M2GKC8zwDbvaMi93OAA7TRUHDvrofgt2Umqk2PyJXepRnpmb5/GnFXpPwXcWa3dyAIfm6quMNyB6FTASv33bmgzHO9muraZgGq4g2rWfcJnwx9fB7R4BaSNQ7421uqFH7aCaWisEZYM+N31vuFTLfOgdU5PY5I84RONS1Efqu/1l1UOWSKVmx+PlwXLCEU6NAIeWPmnf1IiF9cpz1n8+6w1ULUDro+Fu+IRutn1FjVrZR7hper6PY=" { failures.append("Argus compatibility vector 1") } } catch { failures.append("Argus AES failure") }
        do { if hex(try aesCBC([107, 193, 190, 226, 46, 64, 159, 150, 233, 61, 126, 17, 115, 147, 23, 42], key: [43, 126, 21, 22, 40, 174, 210, 166, 171, 247, 21, 136, 9, 207, 79, 60], iv: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15])) != "7649abac8119b246cee98e9b12e9197d8964e0b149c10b7b682e6e39aaeb731c" { failures.append("AES NIST/padding vector 0") } } catch { failures.append("AES failure") }
        // END REFERENCE VECTORS
        return failures
    }
}
// END NATIVE SIGNING CORE
