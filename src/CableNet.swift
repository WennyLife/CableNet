import AppKit
import SwiftUI
import SystemConfiguration
import CoreWLAN
import ServiceManagement
import CoreLocation
import Darwin

// MARK: - Core Enums & Probes (Preserved)

enum InternetHealth: Equatable { case checking, online, offline }

final class InternetProbe {
    var onChange: ((InternetHealth, Int?) -> Void)?
    private var generation = 0
    private var task: URLSessionDataTask?
    private var timer: Timer?
    private var requestStart: TimeInterval = 0
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 7
        config.timeoutIntervalForResource = 9
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()
    private let targets = [
        ("https://www.apple.com/library/test/success.html", "<title>Success</title>"),
        ("https://captive.apple.com/hotspot-detect.html", "<title>Success</title>")
    ]

    func start() {
        stop(); check()
        timer = Timer(timeInterval: 90, repeats: true) { [weak self] _ in self?.check() }
        timer?.tolerance = 15
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        generation += 1; task?.cancel(); task = nil; timer?.invalidate(); timer = nil
    }

    func check() {
        generation += 1; task?.cancel()
        let token = generation
        onChange?(.checking, nil)
        requestStart = ProcessInfo.processInfo.systemUptime
        request(index: 0, token: token)
    }

    private func request(index: Int, token: Int) {
        guard generation == token else { return }
        guard let url = URL(string: targets[index].0) else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        task = session.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                let latency = Int((ProcessInfo.processInfo.systemUptime - self.requestStart) * 1000)
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
                   body.lowercased().contains(self.targets[index].1.lowercased()) {
                    self.task = nil
                    self.onChange?(.online, max(1, latency))
                } else if index + 1 < self.targets.count {
                    self.request(index: index + 1, token: token)
                } else {
                    self.task = nil
                    self.onChange?(.offline, nil)
                }
            }
        }
        task?.resume()
    }
}

enum Connection: String, Equatable { case ethernet, wifi, other, offline }

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
            let patterns = ["State:/Network/Interface/.*/Link", "State:/Network/Interface/.*/IPv4", "State:/Network/Interface/.*/AirPort", "Setup:/Network/Service/.*"]
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
        let interfaces = (SCNetworkInterfaceCopyAll() as NSArray as? [SCNetworkInterface]) ?? []

        let wifiDevices = CWWiFiClient.shared().interfaces() ?? []
        let wifiNames = Set(wifiDevices.compactMap { $0.interfaceName })
        let wifiOn = wifiDevices.contains { $0.powerOn() }

        // Prioridade absoluta para cabo de rede conectado e ativo com IP
        let activeEthernet = interfaces.first(where: {
            guard (SCNetworkInterfaceGetInterfaceType($0) as String?) == (kSCNetworkInterfaceTypeEthernet as String),
                  let name = SCNetworkInterfaceGetBSDName($0) as String? else { return false }
            let linkActive = dictionary("State:/Network/Interface/\(name)/Link")["Active"] as? Bool == true
            let hasIPv4 = dictionary("State:/Network/Interface/\(name)/IPv4")["Addresses"] != nil
            return linkActive && hasIPv4
        }).flatMap { SCNetworkInterfaceGetBSDName($0) as String? }

        if let eth = activeEthernet {
            let ethHardware = interfaces.first { (SCNetworkInterfaceGetBSDName($0) as String?) == eth }
            let ethName = ethHardware.flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? } ?? "USB 10/100/1000 LAN"
            return NetworkState(connection: .ethernet, interface: eth, service: ethName, wifiEnabled: wifiOn)
        }

        if interface.isEmpty {
            interface = interfaces.first(where: {
                guard (SCNetworkInterfaceGetInterfaceType($0) as String?) == (kSCNetworkInterfaceTypeEthernet as String),
                      let name = SCNetworkInterfaceGetBSDName($0) as String? else { return false }
                return dictionary("State:/Network/Interface/\(name)/Link")["Active"] as? Bool == true
            }).flatMap { SCNetworkInterfaceGetBSDName($0) as String? } ?? ""
        }
        let hardware = interfaces.first { (SCNetworkInterfaceGetBSDName($0) as String?) == interface }
        let type = hardware.flatMap { SCNetworkInterfaceGetInterfaceType($0) as String? } ?? interfaceSettings["Type"] as? String ?? ""
        let connection: Connection
        if interface.isEmpty { connection = .offline }
        else if type == (kSCNetworkInterfaceTypeIEEE80211 as String) || wifiNames.contains(interface) { connection = .wifi }
        else if type == (kSCNetworkInterfaceTypeEthernet as String) { connection = .ethernet }
        else { connection = .other }
        return NetworkState(connection: connection, interface: interface,
                            service: service["UserDefinedName"] as? String ?? interface,
                            wifiEnabled: wifiOn)
    }

    func refresh() { onChange?(snapshot()) }
    deinit { if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) } }
}

// MARK: - Menu Bar Status Icon (Preserved 100% as-is per user rule)

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
        guard let base = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil),
              let symbol = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)) else { return nil }
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

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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

// MARK: - Scanned Network Model

struct ScannedNetwork: Identifiable, Equatable {
    var id: String { "\(ssid)_\(channel)_\(bssid)" }
    var ssid: String
    var bssid: String
    var rssi: Int
    var channel: Int
    var band: String
    var isSecure: Bool
    var signalLevel: Int // 1 to 4
    var isCurrent: Bool
}

// MARK: - Panel Model & Data Controller

final class CableNetPanelModel: ObservableObject {
    @Published var state = NetworkState(connection: .offline, interface: "", service: "", wifiEnabled: false)
    @Published var health: InternetHealth = .checking
    @Published var latencyMs: Int? = 7
    @Published var currentSSID: String = UserDefaults.standard.string(forKey: "lastKnownSSID") ?? "Wi-Fi Conectado"
    @Published var currentBand: String = "5 GHz"
    @Published var currentChannel: Int = 0
    @Published var currentSignalStr: String = "—"
    @Published var localIP: String = "—"
    @Published var networks: [ScannedNetwork] = []
    @Published var isScanning = false
    @Published var liveDownSpeed: String = "0 KB/s"
    @Published var liveUpSpeed: String = "0 KB/s"
    @Published var isSpeedTesting = false
    @Published var speedProgress: Double = 0.0
    @Published var maxSpeedVal: String = "320 Mbps"
    @Published var speedPingVal: String = "21 ms"
    @Published var spinRefresh = false
    @Published var animationsEnabled: Bool = true
    @Published var loginWithMac: Bool = false

    private var trafficTimer: Timer?
    private var lastBytes: (ibytes: UInt64, obytes: UInt64)?
    private var lastTimestamp: TimeInterval = 0
    private let locManager = CLLocationManager()

    var onToggleAnimations: (() -> Void)?
    var onCheckInternet: (() -> Void)?

    init() {
        animationsEnabled = !UserDefaults.standard.bool(forKey: "disableAnimations")
        loginWithMac = SMAppService.mainApp.status == .enabled
        if CLLocationManager.locationServicesEnabled() {
            locManager.requestWhenInUseAuthorization()
        }
    }

    func onOpen() {
        refreshInfo()
        scanWifi()
        startTrafficMonitor()
    }

    func onClose() {
        stopTrafficMonitor()
    }

    func getCachedSSID() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "CableNet-SSID" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Interface/en0/AirPort" as CFString) as? [String: Any],
              let data = dict["CachedScanRecord"] as? Data else { return nil }
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = false
            if let decoded = unarchiver.decodeObject(forKey: "root") as? [String: Any],
               let ssid = decoded["SSID_STR"] as? String, !ssid.isEmpty {
                return ssid
            }
        } catch { }
        return nil
    }

    func refreshInfo() {
        localIP = getLocalIP(for: state.interface) ?? "—"
        if state.connection == .ethernet {
            currentSSID = "Cabo de Rede (Gigabit)"
            currentSignalStr = "Cabo Direto (100%)"
            currentBand = "Ethernet"
            currentChannel = 0
        } else if let iface = CWWiFiClient.shared().interface() {
            if let ch = iface.wlanChannel() {
                currentChannel = ch.channelNumber
                currentBand = ch.channelBand == .band5GHz ? "5 GHz" : (ch.channelBand == .band2GHz ? "2.4 GHz" : "6 GHz")
            }
            let rssi = iface.rssiValue()
            if rssi != 0 {
                let quality = rssi >= -55 ? "Excelente" : (rssi >= -70 ? "Bom" : "Médio")
                currentSignalStr = "\(rssi) dBm (\(quality))"
            }
            let direct = iface.ssid() ?? getCachedSSID()
            if let direct, !direct.isEmpty {
                currentSSID = direct
                UserDefaults.standard.set(direct, forKey: "lastKnownSSID")
            } else if let saved = UserDefaults.standard.string(forKey: "lastKnownSSID"), !saved.isEmpty {
                currentSSID = saved
            } else if currentChannel > 0 {
                currentSSID = "Wi-Fi (\(currentBand) · Ch \(currentChannel))"
            }
        } else {
            currentSSID = "Sem Conexão"
            currentSignalStr = "—"
        }
    }

    func scanWifi() {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = CWWiFiClient()
            guard let iface = client.interface() else {
                DispatchQueue.main.async { self.isScanning = false }
                return
            }
            var result: [ScannedNetwork] = []
            var seen = Set<String>()
            let directSSID = iface.ssid() ?? self.getCachedSSID() ?? ""
            let currentChannel = iface.wlanChannel()?.channelNumber ?? 0
            let currentRssi = iface.rssiValue()

            if let raw = try? iface.scanForNetworks(withSSID: nil) {
                for net in raw {
                    guard let ssid = net.ssid, !ssid.isEmpty else { continue }
                    let key = "\(ssid)_\(net.wlanChannel?.channelNumber ?? 0)"
                    if seen.contains(key) { continue }
                    seen.insert(key)
                    let band: String
                    if let chBand = net.wlanChannel?.channelBand {
                        switch chBand {
                        case .band2GHz: band = "2.4G"
                        case .band5GHz: band = "5G"
                        case .band6GHz: band = "6G"
                        case .bandUnknown: band = "Wi-Fi"
                        @unknown default: band = "Wi-Fi"
                        }
                    } else { band = "Wi-Fi" }
                    let level: Int
                    if net.rssiValue >= -55 { level = 4 }
                    else if net.rssiValue >= -70 { level = 3 }
                    else if net.rssiValue >= -82 { level = 2 }
                    else { level = 1 }

                    let isCurr = (!directSSID.isEmpty && directSSID == ssid) ||
                                 (currentChannel != 0 && currentChannel == net.wlanChannel?.channelNumber && abs(net.rssiValue - currentRssi) < 18)

                    result.append(ScannedNetwork(
                        ssid: ssid,
                        bssid: net.bssid ?? "",
                        rssi: net.rssiValue,
                        channel: net.wlanChannel?.channelNumber ?? 0,
                        band: band,
                        isSecure: net.beaconInterval > 0,
                        signalLevel: level,
                        isCurrent: isCurr
                    ))
                }
            }

            result.sort {
                if $0.isCurrent != $1.isCurrent { return $0.isCurrent && !$1.isCurrent }
                return $0.rssi > $1.rssi
            }

            DispatchQueue.main.async {
                self.networks = result
                self.isScanning = false
                if self.state.connection == .wifi {
                    if let currentMatch = result.first(where: { $0.isCurrent }) {
                        self.currentSSID = currentMatch.ssid
                        UserDefaults.standard.set(currentMatch.ssid, forKey: "lastKnownSSID")
                        self.currentBand = currentMatch.band == "5G" ? "5 GHz" : (currentMatch.band == "2.4G" ? "2.4 GHz" : "6 GHz")
                        self.currentChannel = currentMatch.channel
                    } else if let cached = self.getCachedSSID(), !cached.isEmpty {
                        self.currentSSID = cached
                        UserDefaults.standard.set(cached, forKey: "lastKnownSSID")
                    }
                }
            }
        }
    }

    private func startTrafficMonitor() {
        stopTrafficMonitor()
        lastBytes = getInterfaceBytes(interface: state.interface)
        lastTimestamp = ProcessInfo.processInfo.systemUptime
        trafficTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.measureLiveTraffic()
        }
        trafficTimer?.tolerance = 0.1
        RunLoop.main.add(trafficTimer!, forMode: .common)
    }

    private func stopTrafficMonitor() {
        trafficTimer?.invalidate(); trafficTimer = nil; lastBytes = nil
    }

    private func measureLiveTraffic() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let current = getInterfaceBytes(interface: state.interface) else { return }
        if let previous = lastBytes {
            let elapsed = max(0.1, now - lastTimestamp)
            let downDelta = current.ibytes >= previous.ibytes ? current.ibytes - previous.ibytes : 0
            let upDelta = current.obytes >= previous.obytes ? current.obytes - previous.obytes : 0
            liveDownSpeed = formatSpeed(Double(downDelta) / elapsed)
            liveUpSpeed = formatSpeed(Double(upDelta) / elapsed)
        }
        lastBytes = current
        lastTimestamp = now
    }

    private func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSec / 1_048_576)
        } else if bytesPerSec >= 1024 {
            return String(format: "%.0f KB/s", bytesPerSec / 1024)
        } else {
            return String(format: "%.0f B/s", bytesPerSec)
        }
    }

    func runSpeedTest() {
        guard !isSpeedTesting else { return }
        isSpeedTesting = true
        speedProgress = 0.15
        maxSpeedVal = "medindo…"
        speedPingVal = "…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
            process.arguments = ["-c", "-M", "4"]
            let pipe = Pipe()
            process.standardOutput = pipe

            DispatchQueue.main.async { self.speedProgress = 0.55 }

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let dlThroughput = json["dl_throughput"] as? Double ?? 0
                    let baseRtt = json["base_rtt"] as? Double ?? 0
                    let dlMbps = Int(dlThroughput / 1_000_000)
                    let ping = Int(baseRtt)

                    DispatchQueue.main.async {
                        self.speedProgress = 1.0
                        self.maxSpeedVal = "\(dlMbps) Mbps"
                        self.speedPingVal = "\(ping) ms"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            self.isSpeedTesting = false
                            self.speedProgress = 0.0
                        }
                    }
                    return
                }
            } catch { }

            DispatchQueue.main.async {
                self.isSpeedTesting = false
                self.speedProgress = 0.0
                self.maxSpeedVal = "Indisponível"
            }
        }
    }

    func toggleAnimationsAction() {
        animationsEnabled.toggle()
        UserDefaults.standard.set(!animationsEnabled, forKey: "disableAnimations")
        onToggleAnimations?()
    }

    func toggleLoginAction() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            loginWithMac = SMAppService.mainApp.status == .enabled
        } catch { }
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func openNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func quitApp() { NSApp.terminate(nil) }
}

// MARK: - Native C Helper for Live Interface Bytes & Local IP

func getInterfaceBytes(interface: String) -> (ibytes: UInt64, obytes: UInt64)? {
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
    defer { freeifaddrs(ifap) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let name = String(cString: ptr.pointee.ifa_name)
        if name == interface, let data = ptr.pointee.ifa_data {
            let ifData = data.assumingMemoryBound(to: if_data.self)
            return (UInt64(ifData.pointee.ifi_ibytes), UInt64(ifData.pointee.ifi_obytes))
        }
    }
    return nil
}

func getLocalIP(for interface: String) -> String? {
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
    defer { freeifaddrs(ifap) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let name = String(cString: ptr.pointee.ifa_name)
        guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        if name == interface {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            return String(cString: host)
        }
    }
    return nil
}

// MARK: - SwiftUI Panel View

struct CableNetPanelView: View {
    @ObservedObject var model: CableNetPanelModel

    var body: some View {
        VStack(spacing: 11) {
            // Top Bar
            HStack {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(colors: [Color(red: 0, green: 0.78, blue: 0.92), Color(red: 0, green: 0.47, blue: 0.71)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 24, height: 24)
                            .shadow(color: Color(red: 0, green: 0.78, blue: 0.92).opacity(0.4), radius: 4, y: 1)
                        Image(systemName: "wifi")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                    }
                    Text("CableNet")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    Text("v1.1.1")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(white: 0.55))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color(white: 1, opacity: 0.08))
                        .clipShape(Capsule())
                }
                Spacer()
                // Status Internet
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.health == .online ? Color(red: 0.2, green: 0.82, blue: 0.42) : (model.health == .checking ? Color.yellow : Color.red))
                        .frame(width: 6, height: 6)
                        .shadow(color: model.health == .online ? Color.green.opacity(0.8) : Color.clear, radius: 4)
                    Text(model.health == .online ? "Internet ativa" : (model.health == .checking ? "Verificando…" : "Sem internet"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(model.health == .online ? Color(red: 0.2, green: 0.82, blue: 0.42) : (model.health == .checking ? Color.yellow : Color.red))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(model.health == .online ? Color(red: 0.2, green: 0.82, blue: 0.42).opacity(0.12) : Color.red.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.health == .online ? Color(red: 0.2, green: 0.82, blue: 0.42).opacity(0.25) : Color.red.opacity(0.25), lineWidth: 1))
                .clipShape(Capsule())
            }
            .padding(.top, 2)
            .padding(.horizontal, 2)

            // Active Connection Card
            VStack(spacing: 9) {
                HStack(alignment: .center) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(red: 0, green: 0.78, blue: 0.92).opacity(0.18))
                                .frame(width: 38, height: 38)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 0, green: 0.78, blue: 0.92).opacity(0.35), lineWidth: 1))
                            Image(systemName: model.state.connection == .ethernet ? "cable.connector" : (model.state.connection == .wifi ? "wifi" : "wifi.slash"))
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(Color(red: 0, green: 0.78, blue: 0.92))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.state.connection == .ethernet ? "CABO DE REDE CONECTADO" : (model.state.connection == .wifi ? "WI-FI CONECTADO" : "DESCONECTADO"))
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundColor(Color(red: 0, green: 0.78, blue: 0.92))
                                .tracking(0.5)
                            Text(model.currentSSID)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if model.state.connection == .wifi {
                        HStack(spacing: 4) {
                            Text(model.currentBand)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Color(red: 0.22, green: 0.88, blue: 1))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color(red: 0, green: 0.78, blue: 0.92).opacity(0.18))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            if model.currentChannel > 0 {
                                Text("Ch \(model.currentChannel)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Color(white: 0.7))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 3)
                                    .background(Color(white: 1, opacity: 0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    } else if model.state.connection == .ethernet {
                        Text("1 Gbps")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                // 1. Tráfego ao Vivo (Download & Upload)
                HStack(spacing: 8) {
                    HStack(spacing: 7) {
                        Text("↓")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundColor(Color(red: 0, green: 0.78, blue: 0.92))
                            .frame(width: 20, height: 20)
                            .background(Color(red: 0, green: 0.78, blue: 0.92).opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("DOWNLOAD AO VIVO")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundColor(Color(white: 0.55))
                            Text(model.liveDownSpeed)
                                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Rectangle()
                        .fill(Color(white: 1, opacity: 0.1))
                        .frame(width: 1, height: 22)

                    HStack(spacing: 7) {
                        Text("↑")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundColor(Color(red: 0.75, green: 0.35, blue: 0.95))
                            .frame(width: 20, height: 20)
                            .background(Color(red: 0.75, green: 0.35, blue: 0.95).opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("UPLOAD AO VIVO")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundColor(Color(white: 0.55))
                            Text(model.liveUpSpeed)
                                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.28))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // 2. Speed Test Box
                VStack(spacing: 4) {
                    HStack {
                        Button(action: { model.runSpeedTest() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 10))
                                Text(model.isSpeedTesting ? "Testando…" : "Testar Velocidade")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(LinearGradient(colors: [Color(red: 0, green: 0.78, blue: 0.92).opacity(0.35), Color(red: 0, green: 0.58, blue: 0.84).opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(red: 0, green: 0.78, blue: 0.92).opacity(0.5), lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isSpeedTesting)

                        Spacer()

                        HStack(spacing: 12) {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("BANDA MÁX.")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundColor(Color(white: 0.55))
                                Text(model.maxSpeedVal)
                                    .font(.system(size: 11.5, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("PING")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundColor(Color(white: 0.55))
                                Text(model.speedPingVal)
                                    .font(.system(size: 11.5, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    if model.isSpeedTesting {
                        ProgressView(value: model.speedProgress, total: 1.0)
                            .progressViewStyle(.linear)
                            .tint(Color(red: 0, green: 0.78, blue: 0.92))
                            .frame(height: 3)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.22))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Meta Grid
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SINAL")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(Color(white: 0.5))
                        Text(model.currentSignalStr)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("IP LOCAL")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(Color(white: 0.5))
                        Text(model.localIP)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("INTERFACE")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(Color(white: 0.5))
                        Text("\(model.state.interface)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 2)
            }
            .padding(12)
            .background(LinearGradient(colors: [Color(red: 0, green: 0.78, blue: 0.92).opacity(0.12), Color(white: 1, opacity: 0.03)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(red: 0, green: 0.78, blue: 0.92).opacity(0.35), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: Color.black.opacity(0.3), radius: 8, y: 3)

            // Available Networks Section
            HStack {
                Text(model.isScanning && model.networks.isEmpty ? "REDES DISPONÍVEIS (Buscando…)" : "REDES DISPONÍVEIS (\(model.networks.count))")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(Color(white: 0.55))
                    .tracking(0.6)
                Spacer()
                Button(action: {
                    model.spinRefresh = true
                    model.scanWifi()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { model.spinRefresh = false }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(model.spinRefresh ? 360 : 0))
                            .animation(model.spinRefresh ? Animation.linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: model.spinRefresh)
                        Text(model.isScanning ? "Buscando…" : "Atualizar")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(Color(red: 0, green: 0.78, blue: 0.92))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)

            // Networks List
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    if model.networks.isEmpty {
                        if model.isScanning {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Escaneando redes Wi-Fi ao redor…")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(Color(white: 0.6))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                        } else {
                            Text("Nenhuma rede detectada")
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.6))
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                        }
                    } else {
                        ForEach(model.networks) { net in
                            HStack(spacing: 8) {
                                SignalBarsView(level: net.signalLevel)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(net.ssid)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    Text("\(net.band) · Canal \(net.channel)")
                                        .font(.system(size: 10))
                                        .foregroundColor(Color(white: 0.5))
                                }
                                Spacer()
                                if net.isCurrent {
                                    Text("Conectada")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(Color(red: 0.2, green: 0.82, blue: 0.42))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color(red: 0.2, green: 0.82, blue: 0.42).opacity(0.14))
                                        .clipShape(Capsule())
                                } else {
                                    if net.isSecure {
                                        Image(systemName: "lock.fill")
                                            .font(.system(size: 9))
                                            .foregroundColor(Color(white: 0.45))
                                    }
                                    Text(net.band)
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundColor(Color(white: 0.65))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color(white: 1, opacity: 0.08))
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(net.isCurrent ? Color(red: 0, green: 0.78, blue: 0.92).opacity(0.12) : Color(white: 1, opacity: 0.05))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(net.isCurrent ? Color(red: 0, green: 0.78, blue: 0.92).opacity(0.3) : Color.clear, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: model.networks.isEmpty ? 50 : 160)

            Divider().background(Color(white: 1, opacity: 0.12))

            // Actions & Preferences
            VStack(spacing: 3) {
                HStack {
                    Text("Animações do Ícone")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.85))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { model.animationsEnabled },
                        set: { _ in model.toggleAnimationsAction() }
                    ))
                    .toggleStyle(SwitchToggleStyle(tint: Color.green))
                    .scaleEffect(0.7)
                }
                .padding(.horizontal, 6)

                HStack {
                    Text("Iniciar com o Mac")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.85))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { model.loginWithMac },
                        set: { _ in model.toggleLoginAction() }
                    ))
                    .toggleStyle(SwitchToggleStyle(tint: Color.green))
                    .scaleEffect(0.7)
                }
                .padding(.horizontal, 6)

                Button(action: { model.openNetworkSettings() }) {
                    HStack {
                        Text("Ajustes de Rede do Mac…")
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.85))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.5))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }

            Divider().background(Color(white: 1, opacity: 0.12))

            // Footer
            HStack {
                Button(action: { model.quitApp() }) {
                    HStack {
                        Text("Sair do CableNet")
                            .font(.system(size: 12))
                            .foregroundColor(Color(red: 1, green: 0.35, blue: 0.3))
                        Spacer()
                        Text("⌘Q")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(white: 0.45))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.96))
    }
}

// Custom 4-Bar Signal Meter
struct SignalBarsView: View {
    let level: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            bar(height: 4, active: level >= 1)
            bar(height: 7, active: level >= 2)
            bar(height: 10, active: level >= 3)
            bar(height: 13, active: level >= 4)
        }
        .frame(width: 16, height: 13)
    }

    private func bar(height: CGFloat, active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(active ? (level >= 3 ? Color(red: 0, green: 0.78, blue: 0.92) : (level == 2 ? Color.yellow : Color.red)) : Color(white: 1, opacity: 0.18))
            .frame(width: 2.5, height: height)
    }
}

// MARK: - App Delegate & Status Item

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var icon: ConnectionView!
    private var observer: NetworkObserver!
    private let probe = InternetProbe()
    private var health: InternetHealth = .checking
    private var state = NetworkState(connection: .offline, interface: "", service: "", wifiEnabled: false)
    private var popover = NSPopover()
    private let panelModel = CableNetPanelModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: 24)
        guard let button = statusItem.button else { return }

        // Icon preservation
        icon = ConnectionView(frame: button.bounds)
        icon.autoresizingMask = [.width, .height]
        icon.animationsEnabled = panelModel.animationsEnabled
        button.addSubview(icon)

        // Popover configuration
        popover.behavior = .transient
        let hosting = NSHostingController(rootView: CableNetPanelView(model: panelModel))
        hosting.preferredContentSize = NSSize(width: 360, height: 530)
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 360, height: 530)

        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        panelModel.onToggleAnimations = { [weak self] in
            guard let self else { return }
            self.icon.animationsEnabled = self.panelModel.animationsEnabled
            if !self.panelModel.animationsEnabled { self.icon.stopAnimation() }
        }

        panelModel.onCheckInternet = { [weak self] in
            self?.probe.check()
        }

        observer = NetworkObserver()
        probe.onChange = { [weak self] health, latency in
            guard let self else { return }
            self.health = health
            self.icon.health = health
            self.panelModel.health = health
            self.panelModel.latencyMs = latency
            self.statusItem.button?.toolTip = "CableNet — \(self.state.title)\n\(self.healthLabel)"
        }

        observer.onChange = { [weak self] state in self?.apply(state) }
        observer.refresh()
        panelModel.scanWifi()

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)

        if CommandLine.arguments.contains("--self-check") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                let expected = self.observer.snapshot()
                let valid = self.state == expected && self.icon.superview === self.statusItem.button && !self.icon.isAnimating
                print("nativeApp=\(valid ? "PASS" : "FAIL") connection=\(self.state.connection.rawValue) health=\(self.healthLabel) idleAnimation=\(self.icon.isAnimating)")
                NSApp.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--preview-wifi") {
            apply(NetworkState(connection: .wifi, interface: "en0", service: "Wi-Fi", wifiEnabled: true))
        }
        if CommandLine.arguments.contains("--preview-ethernet") {
            apply(NetworkState(connection: .ethernet, interface: "en7", service: "Ethernet", wifiEnabled: true))
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            panelModel.onClose()
        } else {
            panelModel.onOpen()
            icon.stopAnimation()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
    }

    private func apply(_ newState: NetworkState) {
        let changed = newState.connection != state.connection
        state = newState
        icon.connection = state.connection
        panelModel.state = state
        panelModel.refreshInfo()
        statusItem.button?.toolTip = "CableNet — \(state.title)\n\(state.service)\nWi‑Fi \(state.wifiEnabled ? "ligado" : "desligado")"
        statusItem.button?.setAccessibilityLabel("CableNet: \(state.title)")

        if state.connection == .offline {
            probe.stop()
            health = .offline
            icon.health = .offline
            panelModel.health = .offline
        } else {
            probe.start()
        }
        if changed { icon.animate(emphasized: state.connection == .wifi || state.connection == .ethernet) }
    }

    @objc private func wake() {
        observer.refresh()
        if state.connection != .offline { probe.start() }
    }

    @objc private func sleep() {
        icon.stopAnimation()
        probe.stop()
        panelModel.onClose()
    }

    private var healthLabel: String {
        switch health {
        case .checking: return "Verificando internet…"
        case .online: return "Internet disponível"
        case .offline: return "Sem acesso à internet detectado"
        }
    }
}

// MARK: - CLI Diagnostic Entry Points (Preserved)

if CommandLine.arguments.contains("--check-internet") {
    let probe = InternetProbe()
    var finished = false
    probe.onChange = { health, _ in
        if health != .checking {
            print(health == .online ? "internet=online" : "internet=offline")
            finished = true
            probe.stop()
        }
    }
    probe.start()
    let deadline = Date().addingTimeInterval(22)
    while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    if !finished { print("internet=timeout"); exit(1) }
} else if CommandLine.arguments.contains("--diagnose") {
    let state = NetworkObserver().snapshot()
    print("connection=\(state.connection.rawValue) interface=\(state.interface) service=\(state.service) wifiEnabled=\(state.wifiEnabled)")
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
