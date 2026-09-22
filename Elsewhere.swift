import Cocoa
import Foundation
import IOKit.pwr_mgt

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
    lazy var namedTunnelName = envValue("ELSEWHERE_TUNNEL_NAME")
    lazy var namedTunnelHost = envValue("ELSEWHERE_TUNNEL_HOST")
    var useNamedTunnel: Bool { !namedTunnelName.isEmpty && !namedTunnelHost.isEmpty }
    lazy var password = envValue("ELSEWHERE_PASSWORD")
    // Il server ascolta solo su loopback salvo opt-in esplicito: senza, il link
    // Wi-Fi non esiste (ed è comunque HTTP in chiaro, quindi si sceglie a mano)
    lazy var lanEnabled = envValue("ELSEWHERE_BIND") == "0.0.0.0"
    var lanLabel: String { lanEnabled ? localUrl : "disattivata (ELSEWHERE_BIND=0.0.0.0 per abilitarla)" }

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
        localUrl = lanEnabled ? "http://\(getLocalIP()):\(port)" : ""
        macAddress = getHardwareMAC()
        
        // 1. Setup Status Item (Tray Icon)
        setupStatusItem()
        
        // 2. Setup Control Window
        setupWindow()
        
        // 3. Setup Wake / Sleep Observers
        setupWakeObservers()
        
        // 4. Start Background Services & Anti-Sleep
        startServices()
        
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
        
        statusMenuItem = NSMenuItem(title: "Elsewhere: 🟡 Avvio...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        publicUrlMenuItem = NSMenuItem(title: "🌐 Link: In connessione...", action: #selector(copyPublicLink), keyEquivalent: "")
        menu.addItem(publicUrlMenuItem)
        
        copyMenuItem = NSMenuItem(title: "📋 Copia Link Pubblico", action: #selector(copyPublicLink), keyEquivalent: "c")
        menu.addItem(copyMenuItem)
        
        regenMenuItem = NSMenuItem(title: "🔄 Rigenera Link Cloudflare", action: #selector(regenerateLink), keyEquivalent: "r")
        menu.addItem(regenMenuItem)
        
        openMenuItem = NSMenuItem(title: "🌐 Apri nel Browser", action: #selector(openInBrowser), keyEquivalent: "o")
        menu.addItem(openMenuItem)
        
        telegramMenuItem = NSMenuItem(title: "📲 Invia Link su Telegram", action: #selector(triggerSendTelegram), keyEquivalent: "t")
        menu.addItem(telegramMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        localMenuItem = NSMenuItem(title: "🏠 Rete locale: \(lanLabel)", action: #selector(copyLocalLink), keyEquivalent: "")
        menu.addItem(localMenuItem)
        
        pwdMenuItem = NSMenuItem(title: "🔑 Password: \(password)", action: #selector(copyPassword), keyEquivalent: "")
        menu.addItem(pwdMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        antiSleepMenuItem = NSMenuItem(title: "⚡ Anti-Standby: 🟢 Attivo", action: #selector(toggleAntiSleep), keyEquivalent: "")
        menu.addItem(antiSleepMenuItem)
        
        wolMenuItem = NSMenuItem(title: "📡 Dati Wake-on-LAN (WoL)...", action: #selector(showWoLInfo), keyEquivalent: "w")
        menu.addItem(wolMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        let openWinItem = NSMenuItem(title: "🖥️ Apri Pannello di Controllo", action: #selector(showWindow), keyEquivalent: "p")
        menu.addItem(openWinItem)
        
        toggleMenuItem = NSMenuItem(title: "⏸️ Ferma Servizio", action: #selector(toggleService), keyEquivalent: "")
        menu.addItem(toggleMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "🚪 Esci", action: #selector(quitApp), keyEquivalent: "q")
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
        winStatusLabel.stringValue = "🟡 In avvio..."
        winStatusLabel.font = NSFont.systemFont(ofSize: 13)
        winStatusLabel.isEditable = false
        winStatusLabel.isBordered = false
        winStatusLabel.backgroundColor = .clear
        content.addSubview(winStatusLabel)
        
        let sec1 = NSTextField(frame: NSRect(x: 24, y: h - 86, width: 452, height: 18))
        sec1.stringValue = "🌐 LINK PUBBLICO CLOUDFLARE:"
        sec1.font = NSFont.boldSystemFont(ofSize: 11)
        sec1.isEditable = false; sec1.isBordered = false; sec1.backgroundColor = .clear
        content.addSubview(sec1)
        
        winUrlField = NSTextField(frame: NSRect(x: 24, y: h - 126, width: 452, height: 34))
        winUrlField.stringValue = "In attesa di Cloudflare..."
        winUrlField.font = NSFont.systemFont(ofSize: 13)
        winUrlField.isEditable = false
        winUrlField.isSelectable = true
        content.addSubview(winUrlField)
        
        winCopyBtn = NSButton(frame: NSRect(x: 24, y: h - 170, width: 102, height: 32))
        winCopyBtn.title = "📋 Copia"
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
        winRegenBtn.title = "🔄 Rigenera"
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
        sec2.stringValue = "🏠 CONNESSIONE LOCALE & CREDENZIALI:"
        sec2.font = NSFont.boldSystemFont(ofSize: 11)
        sec2.isEditable = false; sec2.isBordered = false; sec2.backgroundColor = .clear
        content.addSubview(sec2)
        
        let locField = NSTextField(frame: NSRect(x: 24, y: h - 250, width: 330, height: 26))
        locField.stringValue = "Rete locale: \(lanLabel)"
        locField.font = NSFont.systemFont(ofSize: 12)
        locField.isEditable = false; locField.isSelectable = true
        content.addSubview(locField)
        
        let copyLocBtn = NSButton(frame: NSRect(x: 364, y: h - 252, width: 112, height: 30))
        copyLocBtn.title = "📋 Copia"
        copyLocBtn.bezelStyle = .rounded
        copyLocBtn.target = self
        copyLocBtn.action = #selector(copyLocalLink)
        content.addSubview(copyLocBtn)
        
        let pwdField = NSTextField(frame: NSRect(x: 24, y: h - 286, width: 330, height: 26))
        pwdField.stringValue = "Password: \(password)"
        pwdField.font = NSFont.systemFont(ofSize: 12)
        pwdField.isEditable = false; pwdField.isSelectable = true
        content.addSubview(pwdField)
        
        let copyPwdBtn = NSButton(frame: NSRect(x: 364, y: h - 288, width: 112, height: 30))
        copyPwdBtn.title = "📋 Copia"
        copyPwdBtn.bezelStyle = .rounded
        copyPwdBtn.target = self
        copyPwdBtn.action = #selector(copyPassword)
        content.addSubview(copyPwdBtn)
        
        // Sezione Anti-Standby e Wake-on-LAN
        let sec3 = NSTextField(frame: NSRect(x: 24, y: h - 330, width: 452, height: 18))
        sec3.stringValue = "⚡ GESTIONE STANDBY & ACCENSIONE (WoL):"
        sec3.font = NSFont.boldSystemFont(ofSize: 11)
        sec3.isEditable = false; sec3.isBordered = false; sec3.backgroundColor = .clear
        content.addSubview(sec3)
        
        winAntiSleepBtn = NSButton(frame: NSRect(x: 24, y: h - 366, width: 330, height: 30))
        winAntiSleepBtn.title = "⚡ Anti-Standby: 🟢 Attivo (Mac sempre sveglio)"
        winAntiSleepBtn.bezelStyle = .rounded
        winAntiSleepBtn.target = self
        winAntiSleepBtn.action = #selector(toggleAntiSleep)
        content.addSubview(winAntiSleepBtn)
        
        winWolBtn = NSButton(frame: NSRect(x: 364, y: h - 366, width: 112, height: 30))
        winWolBtn.title = "📡 Info WoL"
        winWolBtn.bezelStyle = .rounded
        winWolBtn.target = self
        winWolBtn.action = #selector(showWoLInfo)
        content.addSubview(winWolBtn)
        
        let infoLbl = NSTextField(frame: NSRect(x: 24, y: h - 438, width: 452, height: 44))
        infoLbl.stringValue = "💡 Anti-standby impedisce al Mac di addormentarsi durante l'uso da remoto. Se il Mac va in sleep o si risveglia, il tunnel Cloudflare e le notifiche Telegram si ripristinano automaticamente."
        infoLbl.font = NSFont.systemFont(ofSize: 11)
        infoLbl.isEditable = false; infoLbl.isBordered = false; infoLbl.backgroundColor = .clear
        content.addSubview(infoLbl)
        
        winToggleBtn = NSButton(frame: NSRect(x: 24, y: 20, width: 160, height: 34))
        winToggleBtn.title = "⏸️ Ferma Servizio"
        winToggleBtn.bezelStyle = .rounded
        winToggleBtn.target = self
        winToggleBtn.action = #selector(toggleService)
        content.addSubview(winToggleBtn)
        
        let quitBtn = NSButton(frame: NSRect(x: 364, y: 20, width: 112, height: 34))
        quitBtn.title = "🚪 Esci"
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
                    print("⚠️ Porta \(port) occupata da un altro processo (pid \(pid)), non lo tocco")
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
                    print("🩺 Watchdog: server locale non risponde, riavvio...")
                    self.serverProcess?.terminate()
                    self.killServerProcesses()
                    self.startServer()
                    self.sendNotification(title: "Elsewhere 🩺", subtitle: "Watchdog", message: "Server locale riavviato")
                    return
                }

                // 2. Processo cloudflared morto
                if !(self.tunnelProcess?.isRunning ?? false) {
                    print("🩺 Watchdog: cloudflared terminato, riavvio tunnel...")
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
                            print("🩺 Watchdog: link pubblico irraggiungibile, nuovo tunnel...")
                            self.sendNotification(title: "Elsewhere 🩺", subtitle: "Watchdog", message: "Tunnel irraggiungibile, rigenero il link")
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
                            self.isRegenerating = false
                            self.copyToClipboard(url)
                            self.sendNotification(title: "Elsewhere Attivo 🚀", subtitle: "Nuovo link pronto e copiato!", message: url)
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
                self.statusMenuItem.title = "Elsewhere: ⚪ Spento"
                self.publicUrlMenuItem.title = "🌐 Link: Nessuno"
                self.winStatusLabel.stringValue = "⚪ Spento"
                self.winUrlField.stringValue = "Servizio non attivo."
                self.toggleMenuItem.title = "▶️ Avvia Servizio"
                self.winToggleBtn.title = "▶️ Avvia Servizio"
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
                self.statusMenuItem.title = "Elsewhere: 🟡 Connessione..."
                self.publicUrlMenuItem.title = "🌐 Link: In attesa di Cloudflare..."
                self.winStatusLabel.stringValue = "🟡 Connessione..."
                self.winUrlField.stringValue = "Generazione nuovo tunnel Cloudflare in corso..."
                self.toggleMenuItem.title = "⏸️ Ferma Servizio"
                self.winToggleBtn.title = "⏸️ Ferma Servizio"
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
                self.statusMenuItem.title = "Elsewhere: 🟡 Avvio server..."
                let short = self.publicUrl.replacingOccurrences(of: "https://", with: "")
                self.publicUrlMenuItem.title = "🌐 Link: \(short) (avvio...)"
                self.winStatusLabel.stringValue = "🟡 Avvio server locale..."
                self.winUrlField.stringValue = self.publicUrl
                self.toggleMenuItem.title = "⏸️ Ferma Servizio"
                self.winToggleBtn.title = "⏸️ Ferma Servizio"
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
                self.toggleMenuItem.title = "⏸️ Ferma Servizio"
                self.winToggleBtn.title = "⏸️ Ferma Servizio"
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
                self.antiSleepMenuItem?.title = "⚡ Anti-Standby: 🟢 Attivo"
                self.winAntiSleepBtn?.title = "⚡ Anti-Standby: 🟢 Attivo (Mac sempre sveglio)"
            } else if !self.preventSleepEnabled {
                self.antiSleepMenuItem?.title = "⚡ Anti-Standby: ⚪ Disattivato"
                self.winAntiSleepBtn?.title = "⚡ Anti-Standby: ⚪ Disattivato (Standby normale)"
            } else {
                self.antiSleepMenuItem?.title = "⚡ Anti-Standby: ⚪ In Pausa (Servizio Off)"
                self.winAntiSleepBtn?.title = "⚡ Anti-Standby: ⚪ In Pausa (Servizio Off)"
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
            sendNotification(title: "Elsewhere", subtitle: "Link Copiato", message: publicUrl)
        }
    }
    
    @objc func copyLocalLink() {
        guard !localUrl.isEmpty else { return }
        copyToClipboard(localUrl)
        sendNotification(title: "Elsewhere", subtitle: "Link Locale Copiato", message: localUrl)
    }
    
    @objc func copyPassword() {
        copyToClipboard(password)
        sendNotification(title: "Elsewhere", subtitle: "Password Copiata", message: "Negli appunti")
    }
    
    @objc func regenerateLink() {
        guard isRunning else {
            startServices()
            return
        }
        sendNotification(title: "Elsewhere", subtitle: "Rigenerazione...", message: "Nuovo link in arrivo")
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
            sendNotification(title: "Elsewhere", subtitle: "Disattivato", message: "Server e tunnel spenti")
        } else {
            startServices()
            sendNotification(title: "Elsewhere", subtitle: "Avvio...", message: "Server e tunnel in avvio")
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
            sendNotification(title: "Elsewhere", subtitle: "Telegram", message: "Il link pubblico non è ancora pronto.")
            return
        }
        sendNotification(title: "Elsewhere", subtitle: "Telegram", message: "Invio del link in corso...")
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
            print("Credenziali Telegram non trovate")
            if isManual {
                sendNotification(title: "Elsewhere", subtitle: "Telegram", message: "Credenziali Telegram non trovate!")
            }
            return
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
        let timestamp = dateFormatter.string(from: Date())
        let antiSleepDesc = (preventSleepEnabled && isRunning) ? "🟢 Attivo" : "⚪ Spento"
        let mac = macAddress.isEmpty ? getHardwareMAC() : macAddress
        
        let text = """
        🖥️ *Elsewhere è Online!*
        
        🌐 *Link Pubblico (Cloudflare):*
        \(targetUrl)
        
        \(localUrl.isEmpty ? "" : "🏠 *Rete Locale (Wi-Fi):*\n`\(localUrl)`\n\n")\
        ⚡ *Anti-Standby:* \(antiSleepDesc)
        📡 *WoL MAC:* `\(mac)`
        
        ⏰ _\(timestamp)_
        """
        
        guard let endpoint = URL(string: "https://api.telegram.org/bot\(telegramToken)/sendMessage") else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload: [String: Any] = [
            "chat_id": telegramChatId,
            "text": text,
            "parse_mode": "Markdown",
            "disable_web_page_preview": false
        ]
        
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        request.httpBody = body
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                print("Errore invio Telegram: \(error)")
                if isManual {
                    self?.sendNotification(title: "Elsewhere", subtitle: "Telegram", message: "Errore: \(error.localizedDescription)")
                }
            } else {
                print("Notifica Telegram inviata con successo!")
                if isManual {
                    self?.sendNotification(title: "Elsewhere 📲", subtitle: "Telegram", message: "Link inviato al tuo Telegram!")
                }
            }
        }
        task.resume()
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
        print("⚡ Asserzioni anti-standby e anti-schermo-nero attivate (System: \(systemAssertionID), Display: \(displayAssertionID))")
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
        print("🛑 Asserzioni anti-standby rilasciate")
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
            sendNotification(title: "Elsewhere ⚡", subtitle: "Anti-Standby Attivo", message: "Il Mac rimarrà sempre sveglio durante il servizio.")
        } else {
            disableSleepAssertion()
            sendNotification(title: "Elsewhere 💤", subtitle: "Anti-Standby Disattivato", message: "Il Mac potrà andare in standby normalmente.")
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
        print("💤 Standby di sistema rilevato...")
    }
    
    @objc func handleSystemWake(_ notification: Notification) {
        print("☀️ Risveglio del sistema rilevato!")
        sendNotification(title: "Elsewhere ☀️", subtitle: "Mac Risvegliato", message: "Ripristino connessione e riaccensione schermo...")
        
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
            self.localMenuItem?.title = "🏠 Rete locale: \(self.lanLabel)"
            self.updateUI()
            
            // Riavvia il tunnel Cloudflare per riallineare il socket HTTP2
            print("🔄 Riavvio tunnel Cloudflare dopo risveglio da standby...")
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
        alert.messageText = "📡 Parametri Wake-on-LAN (WoL)"
        alert.informativeText = """
        Dati per risvegliare questo Mac da remoto:
        
        • Indirizzo MAC: \(mac)
        • IP Locale (Wi-Fi): \(ip)
        • Porta WoL: 9 (o 7) UDP
        • Scheda di Rete: \(primaryInterfaceName)
        
        Richiede 'Wake for network access' attivo (verifica: pmset -g | grep womp).
        Puoi inviare un Magic Packet da app come 'Mocha WoL', 'Wake On Lan' o dal router.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "📋 Copia MAC")
        alert.addButton(withTitle: "OK")
        
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            copyToClipboard(mac)
            sendNotification(title: "Elsewhere", subtitle: "WoL", message: "MAC copiato: \(mac)")
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
