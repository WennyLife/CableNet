import AppKit
import SystemConfiguration
import CoreWLAN
import ServiceManagement

enum InternetHealth { case checking, online, offline }

final class InternetProbe {
    var onChange: ((InternetHealth) -> Void)?
    private var generation = 0
    private var task: URLSessionDataTask?
    private var timer: Timer?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 7
        config.timeoutIntervalForResource = 9
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()
    private let targets = [("https://www.apple.com/library/test/success.html", "<title>Success</title>"),
                           ("https://captive.apple.com/hotspot-detect.html", "<title>Success</title>")]
    func start() {
        stop(); check()
        timer = Timer(timeInterval: 90, repeats: true) { [weak self] _ in self?.check() }
        timer?.tolerance = 15
        RunLoop.main.add(timer!, forMode: .common)
    }
    func stop() { generation += 1; task?.cancel(); task = nil; timer?.invalidate(); timer = nil }
    func check() {
        generation += 1; task?.cancel()
        let token = generation
        onChange?(.checking)
        request(index: 0, token: token)
    }
    private func request(index: Int, token: Int) {
        guard generation == token else { return }
        var request = URLRequest(url: URL(string: targets[index].0)!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if error == nil, (response as? HTTPURLResponse)?.statusCode == 200, body.lowercased().contains(self.targets[index].1.lowercased()) {
                    self.task = nil; self.onChange?(.online)
                } else if index + 1 < self.targets.count { self.request(index: index + 1, token: token) }
                else { self.task = nil; self.onChange?(.offline) }
            }
        }
        task?.resume()
    }
}

enum Connection: String { case ethernet, wifi, other, offline }

struct NetworkState: Equatable {
    var connection: Connection
    var interface: String
    var service: String
    var wifiEnabled: Bool
    var title: String {
        switch connection {
        case .ethernet: return "Ethernet em uso"
        case .wifi: return "Wi‑Fi em uso"
        case .other: return "Outra conexão em uso"
        case .offline: return "Sem conexão de rede"
        }
    }
}

final class NetworkObserver {
    var onChange: ((NetworkState) -> Void)?
    private var store: SCDynamicStore!
    private var source: CFRunLoopSource?
    init() {
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "CableNet" as CFString, { _, _, pointer in
            guard let pointer else { return }
            Unmanaged<NetworkObserver>.fromOpaque(pointer).takeUnretainedValue().refresh()
        }, &context)
        if let store {
            let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"]
            let patterns = ["State:/Network/Interface/.*/Link", "State:/Network/Interface/.*/AirPort", "Setup:/Network/Service/.*"]
            SCDynamicStoreSetNotificationKeys(store, keys as CFArray, patterns as CFArray)
            source = SCDynamicStoreCreateRunLoopSource(nil, store, 0)
            if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        }
    }
    private func dictionary(_ key: String) -> [String: Any] {
        guard let store else { return [:] }
        return SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] ?? [:]
    }
    func snapshot() -> NetworkState {
        let v4 = dictionary("State:/Network/Global/IPv4")
        let v6 = dictionary("State:/Network/Global/IPv6")
        let primary = v4["PrimaryInterface"] != nil ? v4 : v6
        var interface = primary["PrimaryInterface"] as? String ?? ""
        let serviceID = primary["PrimaryService"] as? String ?? ""
        let service = dictionary("Setup:/Network/Service/\(serviceID)")
        let interfaceSettings = dictionary("Setup:/Network/Service/\(serviceID)/Interface")
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        if interface.isEmpty {
            interface = interfaces.first(where: {
                guard (SCNetworkInterfaceGetInterfaceType($0) as String?) == (kSCNetworkInterfaceTypeEthernet as String), let name = SCNetworkInterfaceGetBSDName($0) as String? else { return false }
                return dictionary("State:/Network/Interface/\(name)/Link")["Active"] as? Bool == true
            }).flatMap { SCNetworkInterfaceGetBSDName($0) as String? } ?? ""
        }
        let hardware = interfaces.first { (SCNetworkInterfaceGetBSDName($0) as String?) == interface }
        let type = hardware.flatMap { SCNetworkInterfaceGetInterfaceType($0) as String? } ?? interfaceSettings["Type"] as? String ?? ""
        let wifiDevices = CWWiFiClient.shared().interfaces() ?? []
        let wifiNames = Set(wifiDevices.compactMap { $0.interfaceName })
        let connection: Connection
        if interface.isEmpty { connection = .offline }
        else if type == (kSCNetworkInterfaceTypeIEEE80211 as String) || wifiNames.contains(interface) { connection = .wifi }
        else if type == (kSCNetworkInterfaceTypeEthernet as String) { connection = .ethernet }
        else { connection = .other }
        return NetworkState(connection: connection, interface: interface,
                            service: service["UserDefinedName"] as? String ?? interface,
                            wifiEnabled: wifiDevices.contains { $0.powerOn() })
    }
    func refresh() { onChange?(snapshot()) }
    deinit { if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) } }
}

final class ConnectionView: NSView {
    var health: InternetHealth = .checking { didSet { needsDisplay = true } }
    var connection: Connection = .offline { didSet { stopAnimation(); needsDisplay = true } }
    var animationsEnabled = true
    var isAnimating: Bool { timer != nil }
    private var timer: Timer?
    private var animationStart: TimeInterval = 0
    private var elapsed: Double = 0
    private var emphasizedEmission = false
    private var tracking: NSTrackingArea?
    private lazy var wifiImage: NSImage? = {
        guard let base = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil), let symbol = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)) else { return nil }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 176, pixelsHigh: 144, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let scale = min(176 / symbol.size.width, 144 / symbol.size.height)
        let rect = NSRect(x: (176 - symbol.size.width * scale) / 2, y: (144 - symbol.size.height * scale) / 2, width: symbol.size.width * scale, height: symbol.size.height * scale)
        symbol.draw(in: rect)
        NSColor(srgbRed: 0, green: 0.75, blue: 0.9, alpha: 1).setFill(); rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: 44, height: 36)
        let image = NSImage(size: bitmap.size); image.addRepresentation(bitmap); return image
    }()
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // The native status button receives clicks.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { animate() }
    override func mouseExited(with event: NSEvent) { stopAnimation() }
    func animate(emphasized: Bool = false) {
        guard health != .offline, animationsEnabled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              connection == .wifi || connection == .ethernet else { return }
        stopAnimation()
        emphasizedEmission = emphasized
        animationStart = ProcessInfo.processInfo.systemUptime
        timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsed = ProcessInfo.processInfo.systemUptime - self.animationStart
            if self.elapsed >= 3.8 { self.stopAnimation() }
            else { self.needsDisplay = true }
        }
        timer?.tolerance = 0.008
        RunLoop.main.add(timer!, forMode: .common)
    }
    func stopAnimation() { timer?.invalidate(); timer = nil; elapsed = 0; needsDisplay = true }
    private func stroke(_ points: [NSPoint], color: NSColor, width: CGFloat) {
        guard let first = points.first else { return }
        let path = NSBezierPath(); path.move(to: first)
        for point in points.dropFirst() { path.line(to: point) }
        path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
        color.setStroke(); path.stroke()
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: floor((bounds.width - 24) / 2), yBy: floor((bounds.height - 22) / 2))
        transform.concat()
        switch connection {
        case .ethernet:
            let compact = NSAffineTransform()
            compact.translateX(by: 0.0, yBy: 1.98)
            compact.scale(by: 0.82)
            compact.concat()
            drawCable()
        case .wifi: drawWiFi()
        case .other: drawSymbol("network", color: health == .offline ? .systemRed : .secondaryLabelColor)
        case .offline: drawSymbol("wifi.slash", color: .systemRed)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    private func drawSymbol(_ name: String, color: NSColor) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let tinted = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            image.draw(in: rect); color.setFill(); rect.fill(using: .sourceAtop); return true
        }
        tinted.draw(in: NSRect(x: 2, y: 1, width: 20, height: 20))
    }
    private func drawCable() {
        let entering = emphasizedEmission && timer != nil
        func reveal(_ start: Double, _ duration: Double) -> Double {
            guard entering else { return 1 }
            return min(1, max(0, (elapsed - start) / duration))
        }
        let neutral = health == .offline ? NSColor.systemRed : NSColor.labelColor
        let green = NSColor(srgbRed: 0.16, green: 0.76, blue: 0.38, alpha: 1)
        // Short curved cable, molded connector and latch. All geometry stays fixed.
        NSGraphicsContext.saveGraphicsState()
        let wireProgress = reveal(0.5, 0.55)
        NSBezierPath(rect: NSRect(x: 10, y: 1, width: 12, height: 8 * wireProgress)).addClip()
        let wire = NSBezierPath(); wire.move(to: NSPoint(x: 11.5, y: 8))
        wire.line(to: NSPoint(x: 11.5, y: 4.5))
        wire.curve(to: NSPoint(x: 20, y: 2.5), controlPoint1: NSPoint(x: 11.5, y: 1), controlPoint2: NSPoint(x: 16, y: 2.5))
        wire.lineWidth = 2; wire.lineCapStyle = .round; neutral.setStroke(); wire.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: 8, width: 22, height: 14 * reveal(0, 0.45))).addClip()
        neutral.setFill()
        NSBezierPath(roundedRect: NSRect(x: 4, y: 8, width: 16, height: 11), xRadius: 2, yRadius: 2).fill()
        NSBezierPath(roundedRect: NSRect(x: 7.7, y: 19, width: 8.6, height: 2), xRadius: 0.8, yRadius: 0.8).fill()
        NSColor.windowBackgroundColor.setFill()
        for x in stride(from: 7.0, through: 17.0, by: 2.5) { NSRect(x: x, y: 15.5, width: 1.2, height: 2.5).fill() }
        NSBezierPath(roundedRect: NSRect(x: 7.7, y: 9.5, width: 8.6, height: 1.4), xRadius: 0.7, yRadius: 0.7).fill()
        NSGraphicsContext.restoreGraphicsState()
        (health == .online ? green : health == .offline ? NSColor.systemRed : NSColor.systemYellow).withAlphaComponent(reveal(1.0, 0.22)).setFill()
        NSBezierPath(ovalIn: NSRect(x: 22.5, y: 8.15, width: 6.1, height: 6.1)).fill()
        guard timer != nil else { return }
        for i in 0..<3 {
            let phase = (elapsed - (emphasizedEmission ? 1.15 : 0) - Double(i) * 0.14).truncatingRemainder(dividingBy: 1.55)
            guard phase >= 0 else { continue }
            let t = phase / 1.55
            let alpha = sin(min(1, t / 0.78) * .pi)
            guard alpha > 0.01 else { continue }
            let rise = 2 * (1 - pow(1 - t, 3))
            let x = CGFloat(6 + i * 5), y = CGFloat(14 + rise)
            let bolt = NSBezierPath()
            bolt.move(to: NSPoint(x: x + 2.5, y: y + 5))
            for p in [NSPoint(x:x,y:y+2), NSPoint(x:x+1.7,y:y+2), NSPoint(x:x+0.7,y:y-1), NSPoint(x:x+4,y:y+3), NSPoint(x:x+2.2,y:y+3)] { bolt.line(to:p) }
            bolt.close(); NSColor.systemYellow.withAlphaComponent(alpha).setFill(); bolt.fill()
        }
    }
    private func drawWiFi() {
        guard let originalImage = wifiImage else { return }
        let image: NSImage = health == .offline ? {
            let red = NSImage(size: originalImage.size)
            red.lockFocus(); originalImage.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.systemRed.setFill(); NSRect(origin: .zero, size: originalImage.size).fill(using: .sourceAtop)
            red.unlockFocus(); return red
        }() : originalImage
        // Apple symbol at its original aspect ratio. No movement or stretching.
        let scale = min(22 / image.size.width, 18 / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(x: (24 - size.width) / 2, y: (22 - size.height) / 2, width: size.width, height: size.height)
        guard timer != nil else { image.draw(in: rect); return }
        for i in 0..<3 {
            let phase = elapsed - Double(i) * 0.22
            var alpha = emphasizedEmission ? 0.12 : 1.0
            if phase >= 0 {
                let t = phase.truncatingRemainder(dividingBy: 2.1) / 2.1
                alpha = emphasizedEmission ? 0.12 + 0.88 * pow(sin(.pi * min(1, t / 0.88)), 2) : 1 - 0.24 * pow(sin(.pi * t), 2)
            }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY + CGFloat(i) * rect.height / 3, width: rect.width, height: rect.height / 3)).addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var icon: ConnectionView!
    private var observer: NetworkObserver!
    private let probe = InternetProbe()
    private var health: InternetHealth = .checking
    private var state = NetworkState(connection: .offline, interface: "", service: "", wifiEnabled: false)
    private var menu = NSMenu()
    func applicationDidFinishLaunching(_ notification: Notification) {
        // One instance only, including when Finder opens the app repeatedly.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: 24)
        guard let button = statusItem.button else { return }
        icon = ConnectionView(frame: button.bounds)
        icon.autoresizingMask = [.width, .height]
        icon.animationsEnabled = !UserDefaults.standard.bool(forKey: "disableAnimations")
        button.addSubview(icon)
        menu.delegate = self; statusItem.menu = menu
        observer = NetworkObserver()
        probe.onChange = { [weak self] health in
            guard let self else { return }
            self.health = health; self.icon.health = health; self.rebuildMenu()
            self.statusItem.button?.toolTip = "CableNet — \(self.state.title)\n\(self.healthLabel)"
        }
        observer.onChange = { [weak self] state in self?.apply(state) }
        observer.refresh()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
        if CommandLine.arguments.contains("--self-check") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
                let expected = self.observer.snapshot()
                let valid = self.state == expected && self.icon.superview === self.statusItem.button && !self.menu.items.isEmpty && !self.icon.isAnimating
                print("nativeApp=\(valid ? "PASS" : "FAIL") connection=\(self.state.connection.rawValue) health=\(self.healthLabel) idleAnimation=\(self.icon.isAnimating) menuItems=\(self.menu.items.count)")
                NSApp.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--show-about") { DispatchQueue.main.async { self.about() } }
        if CommandLine.arguments.contains("--preview-wifi") { apply(NetworkState(connection: .wifi, interface: "Prévia", service: "Prévia", wifiEnabled: true)) }
        if CommandLine.arguments.contains("--preview-ethernet") { apply(NetworkState(connection: .ethernet, interface: "Prévia", service: "Prévia", wifiEnabled: true)) }
    }
    private func apply(_ newState: NetworkState) {
        guard newState != state || menu.items.isEmpty else { return }
        let changed = newState.connection != state.connection
        state = newState; icon.connection = state.connection
        statusItem.button?.toolTip = "CableNet — \(state.title)\n\(state.service)\nWi‑Fi \(state.wifiEnabled ? "ligado" : "desligado")"
        statusItem.button?.setAccessibilityLabel("CableNet: \(state.title)")
        rebuildMenu()
        if state.connection == .offline { probe.stop(); health = .offline; icon.health = .offline }
        else { probe.start() }
        rebuildMenu()
        if changed { icon.animate(emphasized: state.connection == .wifi || state.connection == .ethernet) }
    }
    private func label(_ title: String) { let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }
    @discardableResult private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item); return item
    }
    private func rebuildMenu() {
        menu.removeAllItems()
        label("CableNet"); label(state.title)
        label(healthLabel)
        if !state.interface.isEmpty { label("\(state.service) · \(state.interface)") }
        label("Wi‑Fi \(state.wifiEnabled ? "ligado — disponível para AirDrop" : "desligado")")
        menu.addItem(.separator())
        let animation = action("Animações", #selector(toggleAnimations)); animation.state = icon.animationsEnabled ? .on : .off
        let start = action("Iniciar com o Mac", #selector(toggleLogin)); start.state = SMAppService.mainApp.status == .enabled ? .on : .off
        action("Ajustes de rede…", #selector(openNetworkSettings))
        action("Verificar internet agora", #selector(checkInternet))
        menu.addItem(.separator()); action("Sobre o CableNet…", #selector(about)); action("Sair do CableNet", #selector(quit)).keyEquivalent = "q"
    }
    func menuWillOpen(_ menu: NSMenu) { observer.refresh(); icon.stopAnimation(); rebuildMenu() }
    @objc private func toggleAnimations() { icon.animationsEnabled.toggle(); UserDefaults.standard.set(!icon.animationsEnabled, forKey: "disableAnimations"); if !icon.animationsEnabled { icon.stopAnimation() }; rebuildMenu() }
    @objc private func toggleLogin() {
        do { if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() } }
        catch { showAlert(title: "Não foi possível alterar o início automático", message: "Coloque o CableNet na pasta Aplicativos e tente novamente.\n\(error.localizedDescription)") }
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        rebuildMenu()
    }
    @objc private func openNetworkSettings() { if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") { NSWorkspace.shared.open(url) } }
    @objc private func about() { showAlert(title: "CableNet 1.0.10", message: "Sua conexão, à vista.\n\nRJ45 com ponto verde: Ethernet em uso.\nWi‑Fi ciano: Wi‑Fi em uso.\nCinza: outra conexão ou ausência de rede.\n\nO CableNet acompanha a interface principal do macOS, mantém o Wi‑Fi como está. Verifica acesso à internet a cada 90 segundos usando páginas públicas da Apple, com um segundo endereço como alternativa. O bloqueio dessas páginas pode causar um aviso de falta de internet. VPNs e rotas específicas podem usar outro caminho.\n\nSem coleta de dados. Testes pequenos e espaçados de conexão. Animações curtas ao passar o mouse ou trocar de conexão.") }
    private func showAlert(title: String, message: String) { NSApp.activate(ignoringOtherApps: true); let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.addButton(withTitle: "OK"); alert.runModal() }
    @objc private func wake() { observer.refresh(); if state.connection != .offline { probe.start() } }
    private var healthLabel: String {
        switch health { case .checking: return "Verificando internet…"; case .online: return "Internet disponível"; case .offline: return "Sem acesso à internet detectado" }
    }
    @objc private func checkInternet() { if state.connection != .offline { probe.check() } }
    @objc private func sleep() { icon.stopAnimation(); probe.stop() }
    @objc private func quit() { NSApp.terminate(nil) }
}

// Read-only diagnostics and reproducible rendering for verification.
if CommandLine.arguments.contains("--check-internet") {
    let probe = InternetProbe()
    var finished = false
    probe.onChange = { health in
        if health != .checking { print(health == .online ? "internet=online" : "internet=offline"); finished = true; probe.stop() }
    }
    probe.start()
    let deadline = Date().addingTimeInterval(22)
    while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    if !finished { print("internet=timeout"); exit(1) }
} else if CommandLine.arguments.contains("--diagnose") {
    let state = NetworkObserver().snapshot()
    print("connection=\(state.connection.rawValue) interface=\(state.interface) service=\(state.service) wifiEnabled=\(state.wifiEnabled)")
} else if let index = CommandLine.arguments.firstIndex(of: "--render-icons"), CommandLine.arguments.count > index + 1 {
    let destination = CommandLine.arguments[index + 1]
    _ = NSApplication.shared
    for (connection, health, name) in [(Connection.ethernet, InternetHealth.online, "ethernet"), (.wifi, .online, "wifi"), (.ethernet, .offline, "ethernet-offline"), (.wifi, .offline, "wifi-offline"), (.other, .online, "other"), (.offline, .offline, "offline")] {
        let view = ConnectionView(frame: NSRect(x: 0, y: 0, width: 32, height: 24)); view.connection = connection; view.health = health
        let image = NSImage(size: view.bounds.size)
        image.lockFocus(); view.draw(view.bounds); image.unlockFocus()
        if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: destination).appendingPathComponent("\(name).png"))
        }
    }
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate(); app.delegate = delegate; app.run()
}
