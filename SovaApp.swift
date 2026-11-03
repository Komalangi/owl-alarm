// Сова — нативная оболочка macOS: окно с веб-интерфейсом, иконка в меню-баре, запуск бэкенда.
// Собирается скриптом build_app.sh (swiftc из Command Line Tools). __PROJECT__ подставляется при сборке.
import Cocoa
import WebKit
import ServiceManagement

let PROJECT = "__PROJECT__"
let PYTHON = PROJECT + "/.venv/bin/python"
let MAIN_PY = PROJECT + "/main.py"
let LOG = NSHomeDirectory() + "/Library/Logs/Sova.log"
let PORT = 7781
let BASE = "http://127.0.0.1:\(PORT)"
let AGENT_LABEL = "com.user.sova.app"
let AGENT_PLIST = NSHomeDirectory() + "/Library/LaunchAgents/com.user.sova.app.plist"

func appendLog(_ text: String) {
    let line = "[\(Date())] [Sova.app] \(text)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = FileHandle(forWritingAtPath: LOG) {
        h.seekToEndOfFile(); h.write(data); h.closeFile()
    } else {
        FileManager.default.createFile(atPath: LOG, contents: data)
    }
}

/// Отвечает ли уже кто-то на порту 7781 (синхронно, с коротким таймаутом).
func portAnswers() -> Bool {
    var req = URLRequest(url: URL(string: BASE + "/api/state")!, timeoutInterval: 1.5)
    req.cachePolicy = .reloadIgnoringLocalCacheData
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    URLSession.shared.dataTask(with: req) { _, resp, _ in
        ok = (resp as? HTTPURLResponse) != nil
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 2.5)
    return ok
}

func api(_ method: String, _ path: String, _ body: [String: Any]? = nil, _ done: (([String: Any]) -> Void)? = nil) {
    var req = URLRequest(url: URL(string: BASE + path)!, timeoutInterval: 8)
    req.httpMethod = method
    req.cachePolicy = .reloadIgnoringLocalCacheData
    if let b = body {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: b)
    }
    URLSession.shared.dataTask(with: req) { data, _, _ in
        let obj = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        DispatchQueue.main.async { done?(obj) }
    }.resume()
}

// ───────── бэкенд как дочерний процесс ─────────

final class Backend {
    var proc: Process?
    var quitting = false
    var external = false

    func start() {
        if portAnswers() {
            external = true
            appendLog("порт \(PORT) уже занят работающим сервисом — второй не запускаю")
            return
        }
        launch()
    }

    private func launch() {
        if quitting { return }
        guard FileManager.default.isExecutableFile(atPath: PYTHON) else {
            appendLog("нет интерпретатора: \(PYTHON)")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: PYTHON)
        p.arguments = [MAIN_PY, "serve"]
        p.currentDirectoryURL = URL(fileURLWithPath: PROJECT)
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        if !FileManager.default.fileExists(atPath: LOG) { FileManager.default.createFile(atPath: LOG, contents: nil) }
        if let h = FileHandle(forWritingAtPath: LOG) {
            h.seekToEndOfFile()
            p.standardOutput = h
            p.standardError = h
        }
        p.terminationHandler = { [weak self] pr in
            appendLog("бэкенд завершился (код \(pr.terminationStatus))")
            DispatchQueue.main.async {
                guard let self = self, !self.quitting else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self.quitting { return }
                    // если за это время порт занял кто-то другой — не дублируем
                    if portAnswers() { self.external = true; return }
                    self.launch()
                }
            }
        }
        do {
            try p.run()
            proc = p
            appendLog("бэкенд запущен, pid \(p.processIdentifier)")
        } catch {
            appendLog("не удалось запустить бэкенд: \(error)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.launch() }
        }
    }

    func stop() {
        quitting = true
        if let p = proc, p.isRunning {
            p.terminate()
            let end = Date().addingTimeInterval(2)
            while p.isRunning && Date() < end { usleep(50_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }
}

// ───────── окно ─────────

final class SovaWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class Page: NSObject, WKNavigationDelegate, WKUIDelegate {
    let web: WKWebView
    var attempts = 0

    override init() {
        let cfg = WKWebViewConfiguration()
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]
        if #available(macOS 13.3, *) { web.isInspectable = true }
    }

    func load() {
        web.load(URLRequest(url: URL(string: BASE + "/")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6))
    }

    func retry() {
        attempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempts < 40 ? 0.5 : 3)) { [weak self] in self?.load() }
    }

    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { retry() }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { retry() }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { attempts = 0 }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { load() }

    // ссылки target=_blank (например, страница токена Яндекса) открываем в браузере
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction,
                 windowFeatures f: WKWindowFeatures) -> WKWebView? {
        if let url = a.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    // confirm()/alert() в WKWebView сами не работают — делаем нативные диалоги
    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Отмена")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: "OK")
        a.runModal()
        completionHandler()
    }
}

// ───────── приложение ─────────

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let backend = Backend()
    let page = Page()
    var window: SovaWindow!
    var statusItem: NSStatusItem!
    var listenItem: NSMenuItem!
    var loginItem: NSMenuItem!
    var enabled = false
    var poll: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        // второй экземпляр приложения не нужен
        let me = NSRunningApplication.current
        if let id = me.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != me.processIdentifier }) {
            other.activate(options: [.activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()
        buildWindow()
        buildStatusItem()
        DispatchQueue.global().async {
            self.backend.start()
        }
        page.load()
        showWindow()
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refreshState() }
        refreshState()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ n: Notification) { backend.stop() }

    // главное меню нужно, чтобы работали ⌘C / ⌘V / ⌘A / ⌘Q / ⌘W
    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Выйти из Совы", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Окно")
        win.addItem(withTitle: "Закрыть окно", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        NSApp.mainMenu = main
    }

    func buildWindow() {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window = SovaWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 700), styleMask: style, backing: .buffered, defer: false)
        window.title = "Сова"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.043, green: 0.051, blue: 0.071, alpha: 1)
        window.delegate = self
        window.contentView = page.web
        window.setFrameAutosaveName("SovaMainWindow")
        if !window.setFrameUsingName("SovaMainWindow") { window.center() }
        window.setContentSize(NSSize(width: 380, height: 700))  // окно статичное, размер не меняется
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if #available(macOS 11.0, *), let img = NSImage(systemSymbolName: "bird", accessibilityDescription: "Сова") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "🦉"
        }
        let menu = NSMenu()
        menu.delegate = self
        let open = NSMenuItem(title: "Открыть", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        listenItem = NSMenuItem(title: "Слушаю", action: #selector(toggleListen), keyEquivalent: "")
        listenItem.target = self
        menu.addItem(listenItem)
        loginItem = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let q = NSMenuItem(title: "Выйти", action: #selector(quit), keyEquivalent: "")
        q.target = self
        menu.addItem(q)
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        listenItem.state = enabled ? .on : .off
        loginItem.state = autostartEnabled() ? .on : .off
        refreshState()
    }

    func refreshState() {
        api("GET", "/api/state") { obj in
            if let e = obj["enabled"] as? Bool {
                self.enabled = e
                self.listenItem?.state = e ? .on : .off
            }
        }
    }

    @objc func openWindow() { showWindow() }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func toggleListen() {
        let want = !enabled
        api("POST", "/api/enabled", ["enabled": want]) { obj in
            if (obj["ok"] as? Bool) == true { self.enabled = want } else { appendLog("не удалось переключить «Слушаю»") }
            self.refreshState()
        }
    }

    // ── автозапуск ──
    func autostartEnabled() -> Bool {
        if #available(macOS 13.0, *), SMAppService.mainApp.status == .enabled { return true }
        return FileManager.default.fileExists(atPath: AGENT_PLIST)
    }

    @objc func toggleLogin() {
        if autostartEnabled() { setAutostart(false) } else { setAutostart(true) }
    }

    func setAutostart(_ on: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                if !on { try? FileManager.default.removeItem(atPath: AGENT_PLIST) }
                if SMAppService.mainApp.status == .enabled || !on { return }
            } catch {
                appendLog("SMAppService: \(error) — пробую LaunchAgent")
            }
        }
        if on {
            let app = Bundle.main.bundlePath
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>Label</key><string>\(AGENT_LABEL)</string>
            <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>\(app)</string></array>
            <key>RunAtLoad</key><true/>
            </dict></plist>
            """
            try? FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/Library/LaunchAgents", withIntermediateDirectories: true)
            try? plist.write(toFile: AGENT_PLIST, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: AGENT_PLIST)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
