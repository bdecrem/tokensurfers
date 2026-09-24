import UIKit
import WebKit

/// The agent's run_app tool: loads the HTML in a hidden, phone-sized web view
/// for about two seconds and reports what broke, plus a screenshot.
@MainActor
final class AppRunner: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    static let shared = AppRunner()

    struct Result {
        var errors: [String]
        var notes: [String]
        var jpeg: Data?
    }

    private var web: WKWebView?
    private var errors: [String] = []
    private var notes: [String] = []
    private var finished: CheckedContinuation<Void, Never>?

    /// Console + error capture, injected before any page script runs.
    static let captureScript = """
    (function(){
      var post=function(k,m){try{window.webkit.messageHandlers.surf.postMessage({k:k,m:String(m).slice(0,400)})}catch(e){}};
      window.addEventListener('error',function(e){
        if(e.target&&e.target!==window&&e.target.tagName){post('error','failed to load <'+e.target.tagName.toLowerCase()+'> '+(e.target.src||e.target.href||''));return;}
        post('error','Uncaught '+(e.message||'error')+(e.lineno?' (line '+e.lineno+':'+e.colno+')':''));
      },true);
      window.addEventListener('unhandledrejection',function(e){var r=e.reason;post('error','Unhandled rejection: '+(r&&r.stack||r&&r.message||r));});
      var ce=console.error;console.error=function(){post('error','console.error: '+Array.prototype.join.call(arguments,' '));return ce.apply(console,arguments)};
      var cw=console.warn;console.warn=function(){post('note','console.warn: '+Array.prototype.join.call(arguments,' '));return cw.apply(console,arguments)};
    })();
    """

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(
            WKUserScript(source: Self.captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(self, name: "surf")
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 640), configuration: config)
        w.navigationDelegate = self
        w.uiDelegate = self
        w.isOpaque = true
        // Behind the whole UI (the root view is opaque), so it renders but is never seen.
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first {
            window.insertSubview(w, at: 0)
        }
        return w
    }

    func run(html: String) async -> Result {
        let w = web ?? makeWebView()
        web = w
        errors = []
        notes = []
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finished = c
            w.loadHTMLString(html, baseURL: URL(string: "https://run.tokensurfers.app/"))
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                self.resumeLoad()
            }
        }
        try? await Task.sleep(for: .seconds(1.8))

        // What is actually on the page, so a blank screen is visible to the agent.
        if let info = try? await w.evaluateJavaScript("""
            (function(){var t=(document.body&&document.body.innerText||'').replace(/\\s+/g,' ').trim();
            var c=document.querySelectorAll('canvas').length;
            return 'title: '+document.title+' | canvases: '+c+' | visible text: '+t.slice(0,240);})()
            """) as? String {
            notes.insert(info, at: 0)
        }

        let snap = WKSnapshotConfiguration()
        snap.snapshotWidth = 360
        let image = try? await w.takeSnapshot(configuration: snap)
        let jpeg = image?.jpegData(compressionQuality: 0.6)
        w.loadHTMLString("", baseURL: nil)
        return Result(errors: Array(errors.prefix(20)), notes: notes, jpeg: jpeg)
    }

    private func resumeLoad() {
        finished?.resume()
        finished = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resumeLoad() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        errors.append("navigation failed: \(error.localizedDescription)")
        resumeLoad()
    }

    nonisolated func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let m = body["m"] as? String else { return }
        let kind = body["k"] as? String
        Task { @MainActor in
            if kind == "error" { self.errors.append(m) } else { self.notes.append(m) }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        errors.append("alert() was called (not allowed, build in-page UI): \(message.prefix(120))")
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        errors.append("confirm() was called (not allowed, build in-page UI)")
        completionHandler(true)
    }
}
