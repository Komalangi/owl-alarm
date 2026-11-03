// Сова — нативная оболочка macOS: окно с веб-интерфейсом, иконка в меню-баре, запуск бэкенда.
// Собирается скриптом build_app.sh (swiftc из Command Line Tools).
// Python-часть лежит в Resources/app, данные и venv — в ~/Library/Application Support/Sova.
import Cocoa
import WebKit
import ServiceManagement
import CryptoKit

/// SOVA_SUPPORT_DIR — только для тестов.
let SUPPORT: String = {
    if let o = ProcessInfo.processInfo.environment["SOVA_SUPPORT_DIR"], !o.isEmpty { return o }
    return NSHomeDirectory() + "/Library/Application Support/Sova"
}()
let APP_DIR = (Bundle.main.resourcePath ?? ".") + "/app"
let VENV = SUPPORT + "/venv"
let PYTHON = VENV + "/bin/python"
let HASH_FILE = VENV + "/.req-hash"
let REQ_FILE = APP_DIR + "/requirements.txt"
let MAIN_PY = APP_DIR + "/main.py"
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

    func startNow() { launch() }

    private func launch() {
        if quitting { return }
        guard FileManager.default.isExecutableFile(atPath: PYTHON) else {
            appendLog("нет интерпретатора: \(PYTHON)")
            return
        }
        try? FileManager.default.createDirectory(atPath: SUPPORT, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: PYTHON)
        p.arguments = [MAIN_PY, "serve"]
        p.currentDirectoryURL = URL(fileURLWithPath: SUPPORT)
        var env = ProcessInfo.processInfo.environment
        env["SOVA_HOME"] = SUPPORT
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

// ───────── установка компонентов (venv + pip) ─────────

func sha256Hex(of path: String) -> String? {
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
}

func needsInstall() -> Bool {
    if !FileManager.default.isExecutableFile(atPath: PYTHON) { return true }
    let cur = sha256Hex(of: REQ_FILE) ?? ""
    let saved = (try? String(contentsOfFile: HASH_FILE, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return cur != saved
}

func logTail(_ n: Int = 12) -> String {
    guard let s = try? String(contentsOfFile: LOG, encoding: .utf8) else { return "" }
    return s.split(separator: "\n", omittingEmptySubsequences: true).suffix(n).joined(separator: "\n")
}

/// Запускает процесс, вывод дописывает в лог. Возвращает код выхода.
@discardableResult
func runLogged(_ exe: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
    env["PYTHONUNBUFFERED"] = "1"
    p.environment = env
    if !FileManager.default.fileExists(atPath: LOG) { FileManager.default.createFile(atPath: LOG, contents: nil) }
    if let h = FileHandle(forWritingAtPath: LOG) {
        h.seekToEndOfFile()
        p.standardOutput = h
        p.standardError = h
    }
    appendLog("запуск: \(exe) \(args.joined(separator: " "))")
    do { try p.run() } catch { appendLog("не удалось запустить \(exe): \(error)"); return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

/// Ищет python3 >= 3.9. Второй результат — подсказка для пользователя, если не нашёл.
func findPython() -> String? {
    let cands = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                 "/Library/Frameworks/Python.framework/Versions/Current/bin/python3", "/usr/bin/python3"]
    for c in cands where FileManager.default.isExecutableFile(atPath: c) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c)
        p.arguments = ["-c", "import sys;print(sys.version_info>=(3,9))"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { continue }
        p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if p.terminationStatus == 0 && s.contains("True") { return c }
    }
    return nil
}

/// nil — успех, иначе текст ошибки для пользователя.
func installComponents() -> String? {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: SUPPORT, withIntermediateDirectories: true)
    guard fm.fileExists(atPath: REQ_FILE) else { return "В приложении нет requirements.txt — пакет собран неверно." }
    if !fm.isExecutableFile(atPath: PYTHON) {
        guard let py = findPython() else {
            appendLog("python3 >= 3.9 не найден")
            return "Не нашёл Python 3.9 или новее. Установи Command Line Tools в открывшемся окне и перезапусти Сову. Если окна нет, поставь Python с python.org."
        }
        try? fm.removeItem(atPath: VENV)
        if runLogged(py, ["-m", "venv", VENV]) != 0 { return "Не удалось создать окружение Python (venv)." }
    }
    if runLogged(PYTHON, ["-m", "pip", "install", "--upgrade", "pip"]) != 0 {
        return "Не удалось обновить pip. Проверь интернет."
    }
    if runLogged(PYTHON, ["-m", "pip", "install", "-r", REQ_FILE]) != 0 {
        return "Не удалось установить пакеты. Проверь интернет."
    }
    guard let h = sha256Hex(of: REQ_FILE) else { return "Не прочитал requirements.txt." }
    try? h.write(toFile: HASH_FILE, atomically: true, encoding: .utf8)
    appendLog("компоненты установлены")
    return nil
}

func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}

let PAGE_CSS = """
<meta charset="utf-8"><style>
html,body{margin:0;height:100%;background:#0b0d12;color:#e8eaf0;font:14px -apple-system,Helvetica,Arial,sans-serif}
body{display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;padding:24px;box-sizing:border-box}
.owl{font-size:72px;margin-bottom:12px}h1{font-size:18px;margin:0 0 8px}p{color:#9aa0b0;margin:4px 0}
.spin{width:30px;height:30px;border:3px solid #2a2f3d;border-top-color:#ffc94d;border-radius:50%;animation:s 0.9s linear infinite;margin-top:22px}
@keyframes s{to{transform:rotate(360deg)}}
pre{background:#12151d;color:#9aa0b0;text-align:left;font-size:11px;padding:10px;border-radius:8px;max-width:100%;overflow:auto;max-height:200px;white-space:pre-wrap;word-break:break-all}
button{background:#ffc94d;color:#0b0d12;border:0;border-radius:8px;padding:9px 22px;font-size:14px;font-weight:600;cursor:pointer;margin-top:14px}
.err{color:#ff7a7a}
</style>
"""

// ───────── окно ─────────

final class SovaWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class Page: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let web: WKWebView
    var attempts = 0
    var serving = false          // true — грузим сервис с 127.0.0.1:7781 и ретраим при сбое
    var onRetry: (() -> Void)?

    override init() {
        let cfg = WKWebViewConfiguration()
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(self, name: "sova")
        web.navigationDelegate = self
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]
        if #available(macOS 13.3, *) { web.isInspectable = true }
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        if (m.body as? String) == "retry" { onRetry?() }
    }

    func showInstall() {
        serving = false
        web.loadHTMLString(PAGE_CSS + """
        <div class="owl">🦉</div><h1>Первый запуск</h1>
        <p>Ставлю компоненты… 1–2 минуты.</p><p>Нужен интернет.</p><div class="spin"></div>
        """, baseURL: nil)
    }

    func showError(_ msg: String, _ log: String) {
        serving = false
        web.loadHTMLString(PAGE_CSS + """
        <div class="owl">🦉</div><h1 class="err">Не получилось</h1>
        <p>\(htmlEscape(msg))</p>
        <pre>\(htmlEscape(log))</pre>
        <button onclick="webkit.messageHandlers.sova.postMessage('retry')">Повторить</button>
        """, baseURL: nil)
    }

    func load() {
        serving = true
        web.load(URLRequest(url: URL(string: BASE + "/")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6))
    }

    func retry() {
        if !serving { return }
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
        if ProcessInfo.processInfo.environment["SOVA_SUPPORT_DIR"] == nil, let id = me.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != me.processIdentifier }) {
            other.activate(options: [.activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()
        buildWindow()
        buildStatusItem()
        page.onRetry = { [weak self] in self?.bootstrap() }
        showWindow()
        bootstrap()
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refreshState() }
        refreshState()
    }

    /// Проверка порта → (установка компонентов) → запуск бэкенда → загрузка интерфейса.
    func bootstrap() {
        DispatchQueue.global().async {
            let testOnly = ProcessInfo.processInfo.environment["SOVA_TEST_INSTALL_ONLY"] != nil  // только для тестов
            if !testOnly && portAnswers() {
                self.backend.external = true
                appendLog("порт \(PORT) уже занят работающим сервисом — второй не запускаю")
                DispatchQueue.main.async { self.page.load() }
                return
            }
            if needsInstall() {
                DispatchQueue.main.async { self.page.showInstall() }
                if let err = installComponents() {
                    appendLog("установка не удалась: \(err)")
                    DispatchQueue.main.async { self.page.showError(err, logTail()) }
                    return
                }
            }
            if testOnly { appendLog("тест: установка завершена, бэкенд не запускаю"); return }
            self.backend.startNow()
            DispatchQueue.main.async { self.page.load() }
        }
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
