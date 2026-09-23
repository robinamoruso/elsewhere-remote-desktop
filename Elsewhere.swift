import Cocoa
import Foundation
import IOKit.pwr_mgt
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var window: NSWindow?
    
    // UI Outlets
    var statusMenuItem: NSMenuItem!
    var publicUrlMenuItem: NSMenuItem!
    var copyMenuItem: NSMenuItem!
    var regenMenuItem: NSMenuItem!
    var telegramMenuItem: NSMenuItem!
    var openMenuItem: NSMenuItem!
    var localMenuItem: NSMenuItem!
    var pwdMenuItem: NSMenuItem!
    var toggleMenuItem: NSMenuItem!
    var antiSleepMenuItem: NSMenuItem!
    var wolMenuItem: NSMenuItem!
    var loginMenuItem: NSMenuItem!

    // Settings
    var settingsWindow: NSWindow?
    var fPassword: NSSecureTextField!
    var fTgToken: NSSecureTextField!
    var fTgChat: NSTextField!
    var fTunnelName: NSTextField!
    var fTunnelHost: NSTextField!
    var cLan: NSButton!
    
    // Window elements
    var winStatusLabel: NSTextField!
    var winUrlField: NSTextField!
    var winCopyBtn: NSButton!
    var winOpenBtn: NSButton!
    var winRegenBtn: NSButton!
    var winTelegramBtn: NSButton!
    var winToggleBtn: NSButton!
    var winAntiSleepBtn: NSButton!
    var winWolBtn: NSButton!
    
    // State
    var serverProcess: Process?
    var tunnelProcess: Process?
    var publicUrl: String = ""
    var localUrl: String = ""
    var isRunning: Bool = false
    var isRegenerating: Bool = false
    var isServerReady: Bool = false
    var telegramToken: String = ""
    var telegramChatId: String = ""
    var serverFails: Int = 0
    var publicFails: Int = 0
    let port: Int = 8765
    // Tunnel fisso opzionale (ELSEWHERE_TUNNEL_NAME + ELSEWHERE_TUNNEL_HOST nel .env), altrimenti quick tunnel trycloudflare
    var namedTunnelName = ""
    var namedTunnelHost = ""
    var useNamedTunnel: Bool { !namedTunnelName.isEmpty && !namedTunnelHost.isEmpty }
    var password = ""
    // Il server ascolta solo su loopback salvo opt-in esplicito: senza, il link
    // Wi-Fi non esiste (ed è comunque HTTP in chiaro, quindi si sceglie a mano)
    var lanEnabled = false
    var lanLabel: String { lanEnabled ? localUrl : "off (enable it in Settings)" }

    // Diagnostica su file: lanciata dal Finder, l'app non ha una console
    func appLog(_ msg: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(f.string(from: Date()))  \(msg)\n"
        let path = "\(projectDir)/app.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // Tutta la configurazione si modifica dalla finestra Settings: l'utente
    // non deve mai aprire il .env a mano
    func loadConfig() {
        password       = envValue("ELSEWHERE_PASSWORD")
        telegramToken  = envValue("TELEGRAM_TOKEN")
        telegramChatId = envValue("TELEGRAM_CHAT_ID")
        namedTunnelName = envValue("ELSEWHERE_TUNNEL_NAME")
        namedTunnelHost = envValue("ELSEWHERE_TUNNEL_HOST")
        lanEnabled     = envValue("ELSEWHERE_BIND") == "0.0.0.0"
        localUrl       = lanEnabled ? "http://\(getLocalIP()):\(port)" : ""
    }

    // Riscrive il .env conservando le chiavi che non gestiamo (i commenti no)
    func saveConfig(_ updates: [String: String]) {
        let path = "\(projectDir)/.env"
        var pairs: [String: String] = [:]
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        for line in existing.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            pairs[String(t[t.startIndex..<eq])] = String(t[t.index(after: eq)...])
        }
        for (k, v) in updates {
            if v.isEmpty { pairs.removeValue(forKey: k) } else { pairs[k] = v }
        }
        let body = pairs.keys.sorted().map { "\($0)=\(pairs[$0]!)" }.joined(separator: "\n")
        let text = "# Elsewhere — written by the app's Settings window\n" + body + "\n"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        loadConfig()
    }

    // Variabile d'ambiente, altrimenti letta da ~/.elsewhere/.env
    func envValue(_ key: String) -> String {
        if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v }
        let env = (try? String(contentsOfFile: "\(projectDir)/.env", encoding: .utf8)) ?? ""
        for line in env.components(separatedBy: .newlines) where line.hasPrefix("\(key)=") {
            return String(line.dropFirst(key.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        return ""
    }
    
    // Anti-Sleep & Wake-on-LAN State
    var systemAssertionID: IOPMAssertionID = 0
    var displayAssertionID: IOPMAssertionID = 0
    var hasSleepAssertion: Bool = false
    var preventSleepEnabled: Bool = true
    var primaryInterfaceName: String = "en0"
    var macAddress: String = ""
    
    // Dati (venv, .env, log) fuori dalla Scrivania: niente richieste permessi TCC
    let projectDir = "\(NSHomeDirectory())/.elsewhere"
    // Codice (server.py + static/) impacchettato dentro l'app
    let serverScript = Bundle.main.path(forResource: "server", ofType: "py") ?? "\(NSHomeDirectory())/.elsewhere/server.py"
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        loadConfig()
        localUrl = lanEnabled ? "http://\(getLocalIP()):\(port)" : ""
        macAddress = getHardwareMAC()
        
        // 1. Setup Status Item (Tray Icon)
        setupStatusItem()
        
        // 2. Setup Control Window
        setupWindow()
        
        // 3. Setup Wake / Sleep Observers
        setupWakeObservers()
        
        // 4. Start Background Services & Anti-Sleep
        if password.count < 8 || password == "changeme" {
            // Prima installazione: senza password il server rifiuta di partire
            showSettings()
            sendNotification(title: "Elsewhere", subtitle: "Choose a password", message: "Set one in Settings to start the service")
        } else {
            startServices()
        }
        
        // Check timer for tunnel URL
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkTunnelLog()
        }

        // Watchdog: verifica ogni 30s che server e tunnel rispondano davvero
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.runWatchdog()
        }
    }
    
    func getLocalIP() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                let interface = ptr!.pointee
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" || name == "en1" || name == "en2" {
                        primaryInterfaceName = name
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                    &hostname, socklen_t(hostname.count),
                                    nil, socklen_t(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                        break
                    }
                }
                ptr = interface.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
    
    // ── Status Item (Tray) ───────────────────────────────────────────────────
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "display", accessibilityDescription: "Elsewhere") {
                img.isTemplate = true
                button.image = img
            }
            button.imagePosition = .imageLeading
            button.title = ""
        }
        
        let menu = NSMenu()
        
        statusMenuItem = NSMenuItem(title: "Elsewhere: 🟡 Starting…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        publicUrlMenuItem = NSMenuItem(title: "🌐 Link: connecting…", action: #selector(copyPublicLink), keyEquivalent: "")
        menu.addItem(publicUrlMenuItem)
        
        copyMenuItem = NSMenuItem(title: "📋 Copy public link", action: #selector(copyPublicLink), keyEquivalent: "c")
        menu.addItem(copyMenuItem)
        
        regenMenuItem = NSMenuItem(title: "🔄 New Cloudflare link", action: #selector(regenerateLink), keyEquivalent: "r")
        menu.addItem(regenMenuItem)
        
        openMenuItem = NSMenuItem(title: "🌐 Open in browser", action: #selector(openInBrowser), keyEquivalent: "o")
        menu.addItem(openMenuItem)
        
        telegramMenuItem = NSMenuItem(title: "📲 Send link to Telegram", action: #selector(triggerSendTelegram), keyEquivalent: "t")
        menu.addItem(telegramMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        localMenuItem = NSMenuItem(title: "🏠 Local network: \(lanLabel)", action: #selector(copyLocalLink), keyEquivalent: "")
        menu.addItem(localMenuItem)
        
        pwdMenuItem = NSMenuItem(title: "🔑 Copy password", action: #selector(copyPassword), keyEquivalent: "")
        menu.addItem(pwdMenuItem)

        let showPwdItem = NSMenuItem(title: "👁 Show password…", action: #selector(showPassword), keyEquivalent: "")
        menu.addItem(showPwdItem)
        menu.addItem(NSMenuItem.separator())
        
        antiSleepMenuItem = NSMenuItem(title: "⚡ Keep awake: 🟢 On", action: #selector(toggleAntiSleep), keyEquivalent: "")
        menu.addItem(antiSleepMenuItem)
        
        wolMenuItem = NSMenuItem(title: "📡 Wake-on-LAN details…", action: #selector(showWoLInfo), keyEquivalent: "w")
        menu.addItem(wolMenuItem)

        loginMenuItem = NSMenuItem(title: "🚀 Start at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginMenuItem.state = loginItemEnabled ? .on : .off
        menu.addItem(loginMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        let settingsItem = NSMenuItem(title: "⚙︎ Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(settingsItem)

        let openWinItem = NSMenuItem(title: "🖥️ Open control panel", action: #selector(showWindow), keyEquivalent: "p")
        menu.addItem(openWinItem)
        
        toggleMenuItem = NSMenuItem(title: "⏸️ Stop service", action: #selector(toggleService), keyEquivalent: "")
        menu.addItem(toggleMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "🚪 Quit", action: #selector(quitApp), keyEquivalent: "q")
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    // ── Control Window ───────────────────────────────────────────────────────
    func setupWindow() {
        let w: CGFloat = 500, h: CGFloat = 530
        let rect = NSRect(x: 0, y: 0, width: w, height: h)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        window = NSWindow(contentRect: rect, styleMask: styleMask, backing: .buffered, defer: false)
        window?.title = "Elsewhere — Control Panel"
        window?.center()
        window?.delegate = self
        
        guard let content = window?.contentView else { return }
        
        let titleLbl = NSTextField(frame: NSRect(x: 24, y: h - 50, width: 300, height: 32))
        titleLbl.stringValue = "🖥️ Elsewhere"
        titleLbl.font = NSFont.boldSystemFont(ofSize: 20)
        titleLbl.isEditable = false
        titleLbl.isBordered = false
        titleLbl.backgroundColor = .clear
        content.addSubview(titleLbl)
        
        winStatusLabel = NSTextField(frame: NSRect(x: 340, y: h - 46, width: 136, height: 24))
        winStatusLabel.stringValue = "🟡 Starting…"
        winStatusLabel.font = NSFont.systemFont(ofSize: 13)
        winStatusLabel.isEditable = false
        winStatusLabel.isBordered = false
        winStatusLabel.backgroundColor = .clear
        content.addSubview(winStatusLabel)
        
        let sec1 = NSTextField(frame: NSRect(x: 24, y: h - 86, width: 452, height: 18))
        sec1.stringValue = "🌐 PUBLIC CLOUDFLARE LINK:"
        sec1.font = NSFont.boldSystemFont(ofSize: 11)
        sec1.isEditable = false; sec1.isBordered = false; sec1.backgroundColor = .clear
        content.addSubview(sec1)
        
        winUrlField = NSTextField(frame: NSRect(x: 24, y: h - 126, width: 452, height: 34))
        winUrlField.stringValue = "Waiting for Cloudflare…"
        winUrlField.font = NSFont.systemFont(ofSize: 13)
        winUrlField.isEditable = false
        winUrlField.isSelectable = true
        content.addSubview(winUrlField)
        
        winCopyBtn = NSButton(frame: NSRect(x: 24, y: h - 170, width: 102, height: 32))
        winCopyBtn.title = "📋 Copy"
        winCopyBtn.bezelStyle = .rounded
        winCopyBtn.target = self
        winCopyBtn.action = #selector(copyPublicLink)
        content.addSubview(winCopyBtn)
        
        winOpenBtn = NSButton(frame: NSRect(x: 132, y: h - 170, width: 104, height: 32))
        winOpenBtn.title = "🌐 Browser"
        winOpenBtn.bezelStyle = .rounded
        winOpenBtn.target = self
        winOpenBtn.action = #selector(openInBrowser)
        content.addSubview(winOpenBtn)
        
        winRegenBtn = NSButton(frame: NSRect(x: 242, y: h - 170, width: 110, height: 32))
        winRegenBtn.title = "🔄 New link"
        winRegenBtn.bezelStyle = .rounded
        winRegenBtn.target = self
        winRegenBtn.action = #selector(regenerateLink)
        content.addSubview(winRegenBtn)
        
        winTelegramBtn = NSButton(frame: NSRect(x: 358, y: h - 170, width: 118, height: 32))
        winTelegramBtn.title = "📲 Telegram"
        winTelegramBtn.bezelStyle = .rounded
        winTelegramBtn.target = self
        winTelegramBtn.action = #selector(triggerSendTelegram)
        content.addSubview(winTelegramBtn)
        
        let sec2 = NSTextField(frame: NSRect(x: 24, y: h - 216, width: 452, height: 18))
        sec2.stringValue = "🏠 LOCAL NETWORK & CREDENTIALS:"
        sec2.font = NSFont.boldSystemFont(ofSize: 11)
        sec2.isEditable = false; sec2.isBordered = false; sec2.backgroundColor = .clear
        content.addSubview(sec2)
        
        let locField = NSTextField(frame: NSRect(x: 24, y: h - 250, width: 330, height: 26))
        locField.stringValue = "Local network: \(lanLabel)"
        locField.font = NSFont.systemFont(ofSize: 12)
        locField.isEditable = false; locField.isSelectable = true
        content.addSubview(locField)
        
        let copyLocBtn = NSButton(frame: NSRect(x: 364, y: h - 252, width: 112, height: 30))
        copyLocBtn.title = "📋 Copy"
        copyLocBtn.bezelStyle = .rounded
        copyLocBtn.target = self
        copyLocBtn.action = #selector(copyLocalLink)
        content.addSubview(copyLocBtn)
        
        let pwdField = NSTextField(frame: NSRect(x: 24, y: h - 286, width: 330, height: 26))
        pwdField.stringValue = "Password: ••••••••  (show it from the 👁 menu)"
        pwdField.font = NSFont.systemFont(ofSize: 12)
        pwdField.isEditable = false; pwdField.isSelectable = true
        content.addSubview(pwdField)
        
        let copyPwdBtn = NSButton(frame: NSRect(x: 364, y: h - 288, width: 112, height: 30))
        copyPwdBtn.title = "📋 Copy"
        copyPwdBtn.bezelStyle = .rounded
        copyPwdBtn.target = self
        copyPwdBtn.action = #selector(copyPassword)
        content.addSubview(copyPwdBtn)
        
        // Sezione Anti-Standby e Wake-on-LAN
        let sec3 = NSTextField(frame: NSRect(x: 24, y: h - 330, width: 452, height: 18))
        sec3.stringValue = "⚡ SLEEP & WAKE-ON-LAN:"
        sec3.font = NSFont.boldSystemFont(ofSize: 11)
        sec3.isEditable = false; sec3.isBordered = false; sec3.backgroundColor = .clear
        content.addSubview(sec3)
        
        winAntiSleepBtn = NSButton(frame: NSRect(x: 24, y: h - 366, width: 330, height: 30))
        winAntiSleepBtn.title = "⚡ Keep awake: 🟢 On (Mac never sleeps)"
        winAntiSleepBtn.bezelStyle = .rounded
        winAntiSleepBtn.target = self
        winAntiSleepBtn.action = #selector(toggleAntiSleep)
        content.addSubview(winAntiSleepBtn)
        
        winWolBtn = NSButton(frame: NSRect(x: 364, y: h - 366, width: 112, height: 30))
        winWolBtn.title = "📡 WoL info"
        winWolBtn.bezelStyle = .rounded
        winWolBtn.target = self
        winWolBtn.action = #selector(showWoLInfo)
        content.addSubview(winWolBtn)
        
        let infoLbl = NSTextField(frame: NSRect(x: 24, y: h - 438, width: 452, height: 44))
        infoLbl.stringValue = "💡 Keep awake stops the Mac falling asleep while you use it remotely. If it does sleep and wake, the Cloudflare tunnel and the Telegram notification are rebuilt automatically."
        infoLbl.font = NSFont.systemFont(ofSize: 11)
        infoLbl.isEditable = false; infoLbl.isBordered = false; infoLbl.backgroundColor = .clear
        content.addSubview(infoLbl)
        
        winToggleBtn = NSButton(frame: NSRect(x: 24, y: 20, width: 160, height: 34))
        winToggleBtn.title = "⏸️ Stop service"
        winToggleBtn.bezelStyle = .rounded
        winToggleBtn.target = self
        winToggleBtn.action = #selector(toggleService)
        content.addSubview(winToggleBtn)
        
        let quitBtn = NSButton(frame: NSRect(x: 364, y: 20, width: 112, height: 34))
        quitBtn.title = "🚪 Quit"
        quitBtn.bezelStyle = .rounded
        quitBtn.target = self
        quitBtn.action = #selector(quitApp)
        content.addSubview(quitBtn)
        
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window?.orderOut(nil)
        return false
    }
    
    @objc func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // ── Process Management ───────────────────────────────────────────────────
    func cleanProcesses() {
        let pkill2 = Process()
        pkill2.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill2.arguments = ["-9", "-f", tunnelProcessPattern]
        try? pkill2.run(); pkill2.waitUntilExit()

        killServerProcesses()
    }

    // Solo i cloudflared avviati da noi, non gli altri tunnel dell'utente
    var tunnelProcessPattern: String {
        useNamedTunnel ? "cloudflared tunnel .*run \(NSRegularExpression.escapedPattern(for: namedTunnelName))$" : "cloudflared tunnel --url http://127.0.0.1:\(port)"
    }

    // Uccide chi è in ascolto sulla porta del server (non i client connessi)
    func killServerProcesses() {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        try? lsof.run(); lsof.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty {
            for pid in out.components(separatedBy: .whitespacesAndNewlines) {
                // Sulla porta potrebbe esserci un servizio altrui: uccidiamo solo server.py
                guard processCommand(pid).contains("server.py") else {
                    appLog("⚠️ Port \(port) is used by another process (pid \(pid)), leaving it alone")
                    continue
                }
                let k = Process()
                k.executableURL = URL(fileURLWithPath: "/bin/kill")
                k.arguments = ["-9", pid]
                try? k.run(); k.waitUntilExit()
            }
        }
    }

    func processCommand(_ pid: String) -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", pid, "-o", "command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        try? ps.run(); ps.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    
    func startServices() {
        isRunning = true
        isRegenerating = true
        isServerReady = false
        publicUrl = ""
        enableSleepAssertion()
        updateUI()
        
        cleanProcesses()
        try? FileManager.default.removeItem(atPath: "\(projectDir)/tunnel.log")

        startServer()

        // Start Cloudflare Tunnel
        startTunnel()
    }

    func startServer() {
        serverFails = 0
        let fileManager = FileManager.default
        let sLog = "\(projectDir)/server.log"
        try? fileManager.removeItem(atPath: sLog)

        // Start Python Server
        let persistentPyBin = "\(NSHomeDirectory())/.elsewhere/venv/bin/python3"
        var pyBin = persistentPyBin
        if !fileManager.fileExists(atPath: pyBin) {
            pyBin = "/opt/homebrew/bin/python3"
        }
        if !fileManager.fileExists(atPath: pyBin) {
            pyBin = "/usr/bin/python3"
        }
        
        fileManager.createFile(atPath: sLog, contents: nil)

        let server = Process()
        server.executableURL = URL(fileURLWithPath: pyBin)
        server.arguments = ["-u", serverScript]
        server.currentDirectoryURL = URL(fileURLWithPath: projectDir)
        var env = ProcessInfo.processInfo.environment
        env["ELSEWHERE_PASSWORD"] = password
        env["ELSEWHERE_PORT"] = "\(port)"
        env["ELSEWHERE_BIND"] = envValue("ELSEWHERE_BIND")
        env["PYTHONUNBUFFERED"] = "1"
        server.environment = env
        if let outHandle = FileHandle(forWritingAtPath: sLog) {
            server.standardOutput = outHandle
            server.standardError = outHandle
        }
        try? server.run()
        serverProcess = server
    }

    func startTunnel() {
        appLog("avvio tunnel (named: \(useNamedTunnel))")
        isRegenerating = true
        isServerReady = false  // forza nuovo check + notifica Telegram col nuovo link
        publicFails = 0
        publicUrl = ""
        updateUI()
        
        if let p = tunnelProcess, p.isRunning {
            p.terminate()
        }
        
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-9", "-f", tunnelProcessPattern]
        try? pkill.run(); pkill.waitUntilExit()
        
        let tLog = "\(projectDir)/tunnel.log"
        FileManager.default.createFile(atPath: tLog, contents: nil)
        
        var cBin = "/opt/homebrew/bin/cloudflared"
        if !FileManager.default.fileExists(atPath: cBin) {
            cBin = "/usr/local/bin/cloudflared"
        }
        
        let tunnel = Process()
        tunnel.executableURL = URL(fileURLWithPath: cBin)
        if useNamedTunnel {
            // Tunnel fisso: ingress e credenziali in ~/.cloudflared/config.yml
            tunnel.arguments = ["tunnel", "--protocol", "http2", "--no-autoupdate", "run", namedTunnelName]
        } else {
            tunnel.arguments = ["tunnel", "--url", "http://127.0.0.1:\(port)", "--protocol", "http2", "--no-autoupdate"]
        }
        tunnel.currentDirectoryURL = URL(fileURLWithPath: projectDir)
        if let outHandle = FileHandle(forWritingAtPath: tLog) {
            tunnel.standardOutput = outHandle
            tunnel.standardError = outHandle
        }
        try? tunnel.run()
        tunnelProcess = tunnel
    }
    
    func checkServerReady(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else {
            completion(false)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                completion(true)
            } else {
                completion(false)
            }
        }
        task.resume()
    }

    // Verifica end-to-end dal lato Cloudflare (come la vede un client remoto).
    // Usa DNS-over-HTTPS per non dipendere dal DNS/cache locale del Mac.
    func checkPublicReachable(_ url: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "15",
                           "--doh-url", "https://1.1.1.1/dns-query", "\(url)/health"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { completion(false); return }
            p.waitUntilExit()
            let code = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            completion(code == "200")
        }
    }

    // ponytail: soglie fisse (2 fail server, 3 fail pubblico @30s); regolare qui se troppo sensibile
    func runWatchdog() {
        guard isRunning else { return }
        checkServerReady { [weak self] ok in
            DispatchQueue.main.async {
                guard let self = self, self.isRunning else { return }

                // 1. Server Python locale (causa dei 502)
                self.serverFails = ok ? 0 : self.serverFails + 1
                if !(self.serverProcess?.isRunning ?? false) || self.serverFails >= 2 {
                    self.appLog("🩺 Watchdog: local server not responding, restarting…")
                    self.serverProcess?.terminate()
                    self.killServerProcesses()
                    self.startServer()
                    self.sendNotification(title: "Elsewhere 🩺", subtitle: "Watchdog", message: "Local server restarted")
                    return
                }

                // 2. Processo cloudflared morto
                if !(self.tunnelProcess?.isRunning ?? false) {
                    self.appLog("🩺 Watchdog: cloudflared died, restarting the tunnel…")
                    self.startTunnel()
                    return
                }

                // 3. Link pubblico raggiungibile davvero?
                guard ok, self.isServerReady, !self.publicUrl.isEmpty else { return }
                let url = self.publicUrl
                self.checkPublicReachable(url) { reachable in
                    DispatchQueue.main.async {
                        guard self.isRunning, self.publicUrl == url else { return }
                        self.publicFails = reachable ? 0 : self.publicFails + 1
                        if self.publicFails >= 3 {
                            self.appLog("🩺 Watchdog: public link unreachable, new tunnel…")
                            self.sendNotification(title: "Elsewhere 🩺", subtitle: "Watchdog", message: "Tunnel unreachable, rebuilding the link")
                            self.startTunnel()
                        }
                    }
                }
            }
        }
    }

    func checkTunnelLog() {
        guard isRunning && (publicUrl.isEmpty || isRegenerating || !isServerReady) else { return }
        let tLog = "\(projectDir)/tunnel.log"
        guard let content = try? String(contentsOfFile: tLog, encoding: .utf8) else { return }
        
        var foundUrl: String?
        if useNamedTunnel {
            if content.contains("Registered tunnel connection") { foundUrl = "https://\(namedTunnelHost)" }
        } else if let regex = try? NSRegularExpression(pattern: "https://[a-zA-Z0-9._-]*\\.trycloudflare\\.com") {
            let nsString = content as NSString
            if let lastMatch = regex.matches(in: content, range: NSRange(location: 0, length: nsString.length)).last {
                foundUrl = nsString.substring(with: lastMatch.range)
            }
        }
        do {
            if let url = foundUrl {

                // 1. Mostra subito il link Cloudflare non appena generato e copialo negli appunti!
                if url != publicUrl {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.publicUrl = url
                        self.copyToClipboard(url)
                        self.updateUI()
                    }
                }
                
                // 2. Attendi che il server Python locale sia pronto prima di copiare e notificare
                if !isServerReady {
                    checkServerReady { [weak self] ready in
                        guard let self = self, ready else { return }
                        DispatchQueue.main.async {
                            guard !self.isServerReady else { return }
                            self.isServerReady = true
                            self.appLog("server pronto, link \(url)")
                            self.isRegenerating = false
                            self.copyToClipboard(url)
                            self.sendNotification(title: "Elsewhere is up 🚀", subtitle: "New link ready and copied", message: url)
                            self.sendTelegram(targetUrl: url, isManual: false)
                            self.updateUI()
                        }
                    }
                }
            }
        }
    }
    
    func updateUI() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if !self.isRunning {
                self.statusItem.button?.title = " Off"
                self.statusMenuItem.title = "Elsewhere: ⚪ Off"
                self.publicUrlMenuItem.title = "🌐 Link: none"
                self.winStatusLabel.stringValue = "⚪ Off"
                self.winUrlField.stringValue = "Service is not running."
                self.toggleMenuItem.title = "▶️ Start service"
                self.winToggleBtn.title = "▶️ Start service"
                self.copyMenuItem.isEnabled = false
                self.openMenuItem.isEnabled = false
                self.regenMenuItem.isEnabled = false
                self.telegramMenuItem.isEnabled = false
                self.winCopyBtn.isEnabled = false
                self.winOpenBtn.isEnabled = false
                self.winRegenBtn.isEnabled = false
                self.winTelegramBtn.isEnabled = false
            } else if self.publicUrl.isEmpty {
                // In attesa che Cloudflare generi l'URL
                self.statusItem.button?.title = " …"
                self.statusMenuItem.title = "Elsewhere: 🟡 Connecting…"
                self.publicUrlMenuItem.title = "🌐 Link: waiting for Cloudflare…"
                self.winStatusLabel.stringValue = "🟡 Connecting…"
                self.winUrlField.stringValue = "Creating a new Cloudflare tunnel…"
                self.toggleMenuItem.title = "⏸️ Stop service"
                self.winToggleBtn.title = "⏸️ Stop service"
                self.copyMenuItem.isEnabled = false
                self.openMenuItem.isEnabled = false
                self.regenMenuItem.isEnabled = false
                self.telegramMenuItem.isEnabled = false
                self.winCopyBtn.isEnabled = false
                self.winOpenBtn.isEnabled = false
                self.winRegenBtn.isEnabled = false
                self.winTelegramBtn.isEnabled = false
            } else if !self.isServerReady {
                // Link Cloudflare pronto, server locale in preparazione!
                self.statusItem.button?.title = " …"
                self.statusMenuItem.title = "Elsewhere: 🟡 Starting server…"
                let short = self.publicUrl.replacingOccurrences(of: "https://", with: "")
                self.publicUrlMenuItem.title = "🌐 Link: \(short) (starting…)"
                self.winStatusLabel.stringValue = "🟡 Starting local server…"
                self.winUrlField.stringValue = self.publicUrl
                self.toggleMenuItem.title = "⏸️ Stop service"
                self.winToggleBtn.title = "⏸️ Stop service"
                self.copyMenuItem.isEnabled = true
                self.openMenuItem.isEnabled = true
                self.regenMenuItem.isEnabled = true
                self.telegramMenuItem.isEnabled = false
                self.winCopyBtn.isEnabled = true
                self.winOpenBtn.isEnabled = true
                self.winRegenBtn.isEnabled = true
                self.winTelegramBtn.isEnabled = false
            } else {
                // Server locale pronto e online
                self.statusItem.button?.title = ""
                self.statusMenuItem.title = "Elsewhere: 🟢 Online"
                let short = self.publicUrl.replacingOccurrences(of: "https://", with: "")
                self.publicUrlMenuItem.title = "🌐 Link: \(short)"
                self.winStatusLabel.stringValue = "🟢 Online"
                self.winUrlField.stringValue = self.publicUrl
                self.toggleMenuItem.title = "⏸️ Stop service"
                self.winToggleBtn.title = "⏸️ Stop service"
                self.copyMenuItem.isEnabled = true
                self.openMenuItem.isEnabled = true
                self.regenMenuItem.isEnabled = true
                self.telegramMenuItem.isEnabled = true
                self.winCopyBtn.isEnabled = true
                self.winOpenBtn.isEnabled = true
                self.winRegenBtn.isEnabled = true
                self.winTelegramBtn.isEnabled = true
            }
            
            // Anti-Sleep UI status
            if self.preventSleepEnabled && self.isRunning {
                self.antiSleepMenuItem?.title = "⚡ Keep awake: 🟢 On"
                self.winAntiSleepBtn?.title = "⚡ Keep awake: 🟢 On (Mac never sleeps)"
            } else if !self.preventSleepEnabled {
                self.antiSleepMenuItem?.title = "⚡ Keep awake: ⚪ Off"
                self.winAntiSleepBtn?.title = "⚡ Keep awake: ⚪ Off (normal sleep)"
            } else {
                self.antiSleepMenuItem?.title = "⚡ Keep awake: ⚪ Paused (service off)"
                self.winAntiSleepBtn?.title = "⚡ Keep awake: ⚪ Paused (service off)"
            }
        }
    }
    
    // ── Helper Actions ───────────────────────────────────────────────────────
    func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
    
    func sendNotification(title: String, subtitle: String, message: String) {
        let script = "display notification \"\(message)\" with title \"\(title)\" subtitle \"\(subtitle)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
    
    @objc func copyPublicLink() {
        if !publicUrl.isEmpty {
            copyToClipboard(publicUrl)
            sendNotification(title: "Elsewhere", subtitle: "Link copied", message: publicUrl)
        }
    }
    
    @objc func copyLocalLink() {
        guard !localUrl.isEmpty else { return }
        copyToClipboard(localUrl)
        sendNotification(title: "Elsewhere", subtitle: "Local link copied", message: localUrl)
    }
    
    @objc func copyPassword() {
        copyToClipboard(password)
        sendNotification(title: "Elsewhere", subtitle: "Password copied", message: "In your clipboard")
    }
    
    // In chiaro solo su richiesta esplicita: il pannello finisce nei frame
    // inviati a chi è collegato da remoto
    @objc func showPassword() {
        let alert = NSAlert()
        alert.messageText = "🔑 Elsewhere password"
        alert.informativeText = password
        alert.addButton(withTitle: "📋 Copy")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn { copyPassword() }
    }

    @objc func regenerateLink() {
        guard isRunning else {
            startServices()
            return
        }
        sendNotification(title: "Elsewhere", subtitle: "New link…", message: "Generating a fresh URL")
        startTunnel()
    }
    
    @objc func openInBrowser() {
        let target = !publicUrl.isEmpty ? publicUrl : localUrl
        guard !target.isEmpty else { return }
        if let url = URL(string: target) {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc func toggleService() {
        if isRunning {
            isRunning = false
            isServerReady = false
            publicUrl = ""
            disableSleepAssertion()
            tunnelProcess?.terminate()
            serverProcess?.terminate()
            cleanProcesses()
            updateUI()
            sendNotification(title: "Elsewhere", subtitle: "Stopped", message: "Server and tunnel are off")
        } else {
            startServices()
            sendNotification(title: "Elsewhere", subtitle: "Starting…", message: "Server and tunnel are starting")
        }
    }
    
    @objc func quitApp() {
        disableSleepAssertion()
        tunnelProcess?.terminate()
        serverProcess?.terminate()
        cleanProcesses()
        NSApplication.shared.terminate(nil)
    }
    
    @objc func triggerSendTelegram() {
        guard !publicUrl.isEmpty else {
            sendNotification(title: "Elsewhere", subtitle: "Telegram", message: "The public link isn't ready yet.")
            return
        }
        sendNotification(title: "Elsewhere", subtitle: "Telegram", message: "Sending the link…")
        sendTelegram(targetUrl: publicUrl, isManual: true)
    }
    
    func loadTelegramCredentials() {
        telegramToken = envValue("TELEGRAM_TOKEN")
        telegramChatId = envValue("TELEGRAM_CHAT_ID")
    }
    
    func sendTelegram(targetUrl: String, isManual: Bool = false) {
        if telegramToken.isEmpty || telegramChatId.isEmpty {
            loadTelegramCredentials()
        }
        guard !telegramToken.isEmpty, !telegramChatId.isEmpty else {
            appLog("Telegram credentials not found")
            if isManual {
                sendNotification(title: "Elsewhere", subtitle: "Telegram", message: "Telegram credentials not found")
            }
            return
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
        let timestamp = dateFormatter.string(from: Date())
        let antiSleepDesc = (preventSleepEnabled && isRunning) ? "🟢 on" : "⚪ off"
        let mac = macAddress.isEmpty ? getHardwareMAC() : macAddress
        
        let text = """
        🖥️ *Elsewhere is online*
        
        🌐 *Public link (Cloudflare):*
        \(targetUrl)
        
        \(localUrl.isEmpty ? "" : "🏠 *Local network (Wi-Fi):*\n`\(localUrl)`\n\n")\
        ⚡ *Keep awake:* \(antiSleepDesc)
        📡 *WoL MAC:* `\(mac)`
        
        ⏰ _\(timestamp)_
        """
        
        // Via curl e non URLSession: qui il traffico di URLSession passa dalle
        // estensioni di rete (VPN, relay) e può non uscire affatto. Il token va
        // nel file di configurazione letto da stdin, così non compare in `ps`.
        let config = """
        url = "https://api.telegram.org/bot\(telegramToken)/sendMessage"
        data-urlencode = "chat_id=\(curlEscape(telegramChatId))"
        data-urlencode = "text=\(curlEscape(text))"
        data-urlencode = "parse_mode=Markdown"
        """

        DispatchQueue.global().async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-s", "-S", "--max-time", "20", "--config", "-"]
            let stdinPipe = Pipe(), outPipe = Pipe()
            p.standardInput = stdinPipe
            p.standardOutput = outPipe
            p.standardError = outPipe
            do { try p.run() } catch {
                self?.appLog("Telegram: curl non eseguibile")
                return
            }
            stdinPipe.fileHandleForWriting.write(config.data(using: .utf8)!)
            try? stdinPipe.fileHandleForWriting.close()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()

            let ok = out.contains("\"ok\":true")
            // La risposta non contiene il token, ma il messaggio sì: si logga solo l'esito
            self?.appLog(ok ? "Telegram notification sent" : "Telegram send failed (curl exit \(p.terminationStatus))")
            if isManual {
                DispatchQueue.main.async {
                    self?.sendNotification(title: ok ? "Elsewhere 📲" : "Elsewhere", subtitle: "Telegram",
                                           message: ok ? "Link sent to Telegram" : "Send failed, see app.log")
                }
            }
        }
    }

    // Le stringhe del file di configurazione di curl vanno quotate
    func curlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
    }
    
    // ── Settings ─────────────────────────────────────────────────────────────
    @objc func showSettings() {
        if settingsWindow == nil { buildSettingsWindow() }
        fPassword.stringValue   = password
        fTgToken.stringValue    = telegramToken
        fTgChat.stringValue     = telegramChatId
        fTunnelName.stringValue = namedTunnelName
        fTunnelHost.stringValue = namedTunnelHost
        cLan.state = lanEnabled ? .on : .off
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func label(_ text: String, _ y: CGFloat, bold: Bool = false, small: Bool = false) -> NSTextField {
        let l = NSTextField(frame: NSRect(x: 24, y: y, width: 452, height: small ? 30 : 18))
        l.stringValue = text
        l.font = bold ? NSFont.boldSystemFont(ofSize: 11) : NSFont.systemFont(ofSize: small ? 10 : 12)
        if small { l.textColor = .secondaryLabelColor; l.maximumNumberOfLines = 2 }
        l.isEditable = false; l.isBordered = false; l.backgroundColor = .clear
        return l
    }

    func buildSettingsWindow() {
        let w: CGFloat = 500, h: CGFloat = 430
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Elsewhere — Settings"
        guard let c = win.contentView else { return }

        c.addSubview(label("🔑 PASSWORD (at least 8 characters)", h - 46, bold: true))
        fPassword = NSSecureTextField(frame: NSRect(x: 24, y: h - 76, width: 452, height: 24))
        c.addSubview(fPassword)

        c.addSubview(label("📲 TELEGRAM (optional: the link is sent here)", h - 112, bold: true))
        fTgToken = NSSecureTextField(frame: NSRect(x: 24, y: h - 142, width: 452, height: 24))
        fTgToken.placeholderString = "Bot token from @BotFather"
        c.addSubview(fTgToken)
        fTgChat = NSTextField(frame: NSRect(x: 24, y: h - 172, width: 452, height: 24))
        fTgChat.placeholderString = "Chat ID"
        c.addSubview(fTgChat)

        c.addSubview(label("🌐 FIXED CLOUDFLARE TUNNEL (optional)", h - 208, bold: true))
        fTunnelName = NSTextField(frame: NSRect(x: 24, y: h - 238, width: 452, height: 24))
        fTunnelName.placeholderString = "Tunnel name, e.g. elsewhere"
        c.addSubview(fTunnelName)
        fTunnelHost = NSTextField(frame: NSRect(x: 24, y: h - 268, width: 452, height: 24))
        fTunnelHost.placeholderString = "Hostname, e.g. desk.example.com"
        c.addSubview(fTunnelHost)
        c.addSubview(label("Needs cloudflared tunnel login/create and ~/.cloudflared/config.yml.", h - 292, small: true))

        c.addSubview(label("🏠 LOCAL NETWORK", h - 326, bold: true))
        cLan = NSButton(checkboxWithTitle: "Also answer on the LAN (plain HTTP, trusted networks only)", target: nil, action: nil)
        cLan.frame = NSRect(x: 24, y: h - 352, width: 452, height: 22)
        c.addSubview(cLan)

        let save = NSButton(frame: NSRect(x: 336, y: 20, width: 140, height: 34))
        save.title = "Save and restart"
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.target = self; save.action = #selector(saveSettings)
        c.addSubview(save)

        let cancel = NSButton(frame: NSRect(x: 220, y: 20, width: 100, height: 34))
        cancel.title = "Cancel"
        cancel.bezelStyle = .rounded
        cancel.target = self; cancel.action = #selector(closeSettings)
        c.addSubview(cancel)

        c.addSubview(label("Saved to ~/.elsewhere/.env. Saving restarts the service and creates a new link.", 62, small: true))
        settingsWindow = win
    }

    @objc func closeSettings() { settingsWindow?.orderOut(nil) }

    @objc func saveSettings() {
        let pw = fPassword.stringValue.trimmingCharacters(in: .whitespaces)
        guard pw.count >= 8, pw != "changeme" else {
            let a = NSAlert()
            a.messageText = "Password too short"
            a.informativeText = "Use at least 8 characters. The server refuses to start otherwise."
            a.runModal()
            return
        }
        saveConfig([
            "ELSEWHERE_PASSWORD": pw,
            "TELEGRAM_TOKEN": fTgToken.stringValue.trimmingCharacters(in: .whitespaces),
            "TELEGRAM_CHAT_ID": fTgChat.stringValue.trimmingCharacters(in: .whitespaces),
            "ELSEWHERE_TUNNEL_NAME": fTunnelName.stringValue.trimmingCharacters(in: .whitespaces),
            "ELSEWHERE_TUNNEL_HOST": fTunnelHost.stringValue.trimmingCharacters(in: .whitespaces),
            "ELSEWHERE_BIND": cLan.state == .on ? "0.0.0.0" : "",
        ])
        settingsWindow?.orderOut(nil)
        localMenuItem?.title = "🏠 Local network: \(lanLabel)"
        appLog("configurazione salvata, riavvio del servizio")
        startServices()   // password e bind si applicano solo al riavvio del server
        sendNotification(title: "Elsewhere", subtitle: "Settings saved", message: "Service restarting with the new settings")
    }

    // ── Avvio automatico al login ────────────────────────────────────────────
    var loginItemEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    @objc func toggleLoginItem() {
        guard #available(macOS 13.0, *) else {
            sendNotification(title: "Elsewhere", subtitle: "Start at login", message: "Requires macOS 13 or later")
            return
        }
        do {
            if loginItemEnabled {
                try SMAppService.mainApp.unregister()
                sendNotification(title: "Elsewhere", subtitle: "Start at login", message: "Disabled")
            } else {
                try SMAppService.mainApp.register()
                sendNotification(title: "Elsewhere", subtitle: "Start at login", message: "Elsewhere will start itself after a reboot")
            }
        } catch {
            sendNotification(title: "Elsewhere", subtitle: "Start at login", message: "Error: \(error.localizedDescription)")
        }
        loginMenuItem.state = loginItemEnabled ? .on : .off
    }

    // ── Anti-Sleep (IOKit Assertions) ─────────────────────────────────────────
    func enableSleepAssertion() {
        guard preventSleepEnabled && !hasSleepAssertion else { return }
        let reason = "Elsewhere Server Active" as CFString
        
        // 1. Impedisce che il Mac vada in standby di sistema
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &systemAssertionID
        )
        
        // 2. Impedisce che il display/framebuffer vada in sleep (evita lo schermo nero da remoto!)
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &displayAssertionID
        )
        
        hasSleepAssertion = true
        appLog("⚡ Sleep and display assertions enabled (system: \(systemAssertionID), display: \(displayAssertionID))")
    }
    
    func disableSleepAssertion() {
        guard hasSleepAssertion else { return }
        if systemAssertionID != 0 {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = 0
        }
        if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
        hasSleepAssertion = false
        appLog("🛑 Sleep assertions released")
    }
    
    func wakeDisplay() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-u", "-t", "3"]
        try? p.run()
    }
    
    @objc func toggleAntiSleep() {
        preventSleepEnabled.toggle()
        if preventSleepEnabled {
            if isRunning { enableSleepAssertion() }
            sendNotification(title: "Elsewhere ⚡", subtitle: "Keep awake on", message: "The Mac will stay awake while the service runs.")
        } else {
            disableSleepAssertion()
            sendNotification(title: "Elsewhere 💤", subtitle: "Keep awake off", message: "The Mac can sleep normally again.")
        }
        updateUI()
    }
    
    // ── Wake & Sleep Lifecycle Observers ──────────────────────────────────────
    func setupWakeObservers() {
        let wsNC = NSWorkspace.shared.notificationCenter
        wsNC.addObserver(self, selector: #selector(handleSystemWake), name: NSWorkspace.didWakeNotification, object: nil)
        wsNC.addObserver(self, selector: #selector(handleSystemSleep), name: NSWorkspace.willSleepNotification, object: nil)
    }
    
    @objc func handleSystemSleep(_ notification: Notification) {
        appLog("💤 System going to sleep…")
    }
    
    @objc func handleSystemWake(_ notification: Notification) {
        appLog("☀️ System woke up")
        sendNotification(title: "Elsewhere ☀️", subtitle: "Mac woke up", message: "Restoring the connection and waking the screen…")
        
        // Risveglia istantaneamente lo schermo dallo sleep
        wakeDisplay()
        
        guard isRunning else { return }
        
        if preventSleepEnabled {
            enableSleepAssertion()
        }
        
        // Attendi 3.5 secondi affinché Wi-Fi/Ethernet ristabilisca IP e gateway
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self = self, self.isRunning else { return }
            
            // Sveglia nuovamente il display per sicurezza
            self.wakeDisplay()
            
            // Ricalcola IP locale
            self.localUrl = self.lanEnabled ? "http://\(self.getLocalIP()):\(self.port)" : ""
            self.localMenuItem?.title = "🏠 Local network: \(self.lanLabel)"
            self.updateUI()
            
            // Riavvia il tunnel Cloudflare per riallineare il socket HTTP2
            appLog("🔄 Restarting the Cloudflare tunnel after wake…")
            self.startTunnel()
        }
    }
    
    // ── Wake-on-LAN Helpers ──────────────────────────────────────────────────
    func getHardwareMAC() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-listallhardwareports"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return "" }
        
        var currentDevice = ""
        var foundForActive = ""
        
        for line in output.components(separatedBy: .newlines) {
            if line.contains("Device: ") {
                currentDevice = line.replacingOccurrences(of: "Device: ", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.contains("Ethernet Address: ") {
                let mac = line.replacingOccurrences(of: "Ethernet Address: ", with: "").trimmingCharacters(in: .whitespaces)
                if currentDevice == primaryInterfaceName {
                    return mac
                }
                if foundForActive.isEmpty && !mac.isEmpty {
                    foundForActive = mac
                }
            }
        }
        return foundForActive
    }
    
    @objc func showWoLInfo() {
        let mac = macAddress.isEmpty ? getHardwareMAC() : macAddress
        let ip = getLocalIP()
        let alert = NSAlert()
        alert.messageText = "📡 Wake-on-LAN details"
        alert.informativeText = """
        What you need to wake this Mac remotely:
        
        • MAC address: \(mac)
        • Local IP (Wi-Fi): \(ip)
        • WoL port: 9 (or 7) UDP
        • Interface: \(primaryInterfaceName)
        
        Requires 'Wake for network access' (check with: pmset -g | grep womp).
        Send the magic packet from an app like 'Mocha WoL' or from your router.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "📋 Copy MAC")
        alert.addButton(withTitle: "OK")
        
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            copyToClipboard(mac)
            sendNotification(title: "Elsewhere", subtitle: "WoL", message: "MAC copied: \(mac)")
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        disableSleepAssertion()
        tunnelProcess?.terminate()
        serverProcess?.terminate()
        cleanProcesses()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
