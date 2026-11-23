// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum TVBrand: String, Codable, Sendable {
    case lg, samsung
    /// Android TV: bilgisayar TV'yi denetlemez, TV uygulaması bilgisayarı kendisi bulur.
    case androidTV
}

public struct LGTV: Codable, Hashable, Sendable {
    public let name: String
    public let host: String
    public let brand: TVBrand

    public init(name: String, host: String, brand: TVBrand = .lg) {
        self.name = name
        self.host = host
        self.brand = brand
    }

    /// Eski kayıtlarda marka yoktur; hepsi LG'dir.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        brand = try container.decodeIfPresent(TVBrand.self, forKey: .brand) ?? .lg
    }
}

/// TV'de uygulama başlatabilen ve önplandaki uygulamayı söyleyebilen her şey.
public protocol TVControlling: AnyObject {
    func launch(appId: String, params: [String: Any]) async throws
    func foregroundAppId() async throws -> String
    /// TV'nin donanım boşta sayacını sıfırlar (LG OLED ekran koruyucu önlemi).
    func keepScreenAwake() async
    func close()
}

public extension TVControlling {
    func keepScreenAwake() async {}
}

/// LG TV ile SSAP (WebSocket) üzerinden konuşur. İlk bağlantıda TV ekranında izin sorulur;
/// dönen client-key saklanırsa sonraki bağlantılar sorusuz olur.
public final class SSAPClient: NSObject, TVControlling, URLSessionDelegate, @unchecked Sendable {
    public enum SSAPError: Error { case cannotConnect, rejected(String), badResponse }

    /// Sihirli kumanda imlecini ve sistem bildirimlerini açmadan LG donanım boşta sayacını sıfırlayan tuş komutu.
    static let keepAwakeCommand = "type:button\nname:YELLOW\n\n"

    private let endpoints: [URL]
    private let approvalTimeout: Duration
    private let handshakeTimeout: Duration
    private let onClientKey: (@Sendable (String) -> Void)?
    private let onPermissionsUpgraded: (@Sendable () -> Void)?
    private var clientKey: String?
    private var needsPermissionUpgrade: Bool
    private var session: URLSession!
    private var socket: URLSessionWebSocketTask?
    private var activeEndpoint: URL?
    private var pointerHost: String?
    private var permissionUpgradeAttempted = false
    private var keepAwakeCount = 0
    private var turnOffScreenSaverSupported: Bool?
    private var nextId = 1

    /// Önce şifreli (3001), olmazsa düz (3000) bağlantı denenir; eski webOS'lar yalnız 3000'i açar.
    public convenience init(tv: LGTV, clientKey: String?, needsPermissionUpgrade: Bool = false,
                            onClientKey: (@Sendable (String) -> Void)? = nil,
                            onPermissionsUpgraded: (@Sendable () -> Void)? = nil) {
        self.init(endpoints: Self.endpoints(host: tv.host), clientKey: clientKey,
                  needsPermissionUpgrade: needsPermissionUpgrade, onClientKey: onClientKey,
                  onPermissionsUpgraded: onPermissionsUpgraded)
    }

    /// Adres URL'ye dönüşmezse (ör. elle yazılmış "192.168.1.5:3000") liste boş kalır ve `connect` `cannotConnect`
    /// fırlatır. Eskiden burada zorla açılıyordu ve uygulama kapanıyordu.
    static func endpoints(host: String) -> [URL] {
        [URL(string: "wss://\(host):3001"), URL(string: "ws://\(host):3000")].compactMap { $0 }
    }

    init(endpoints: [URL], clientKey: String?, approvalTimeout: Duration = .seconds(60),
         handshakeTimeout: Duration = .seconds(5), needsPermissionUpgrade: Bool = false,
         onClientKey: (@Sendable (String) -> Void)? = nil,
         onPermissionsUpgraded: (@Sendable () -> Void)? = nil) {
        self.endpoints = endpoints
        self.clientKey = clientKey
        self.approvalTimeout = approvalTimeout
        self.handshakeTimeout = handshakeTimeout
        self.needsPermissionUpgrade = needsPermissionUpgrade
        self.onClientKey = onClientKey
        self.onPermissionsUpgraded = onPermissionsUpgraded
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    /// Eşleşir ve client-key'i döner. Kullanıcı TV'de onay verene kadar bekler (en çok 60 sn).
    /// `needsPermissionUpgrade` açıksa eski anahtarda eksik olan kumanda/güç izinlerini almak için önce tek seferlik
    /// taze onay ister; kullanıcı reddeder ya da zaman aşımına uğrarsa mevcut anahtarla devam eder.
    public func connect() async throws -> String {
        if needsPermissionUpgrade && clientKey != nil && !permissionUpgradeAttempted {
            permissionUpgradeAttempted = true
            SubtitleLog.write("LG TV ekran koruyucu önlemi: eski eşleşmede kumanda izni eksik — TV'de tek seferlik 'Kabul Et' onayı isteniyor")
            do {
                let upgradedKey = try await connectOnce(key: nil, forcePairing: true)
                needsPermissionUpgrade = false
                onPermissionsUpgraded?()
                SubtitleLog.write("LG TV ekran koruyucu önlemi: yeni kumanda/güç izinleri onaylandı ve kalıcı olarak kaydedildi")
                return upgradedKey
            } catch {
                SubtitleLog.write("LG TV izin yükseltme tamamlanmadı (\(error)); mevcut eşleşme ile devam ediliyor")
            }
        }
        return try await connectOnce(key: clientKey, forcePairing: false)
    }

    private func connectOnce(key: String?, forcePairing: Bool) async throws -> String {
        for url in endpoints {
            let task = session.webSocketTask(with: url)
            task.resume()
            do {
                try await sendRegistration(on: task, clientKey: key, forcePairing: forcePairing)
                let receivedKey = try await waitForRegistration(on: task)
                socket = task
                activeEndpoint = url
                clientKey = receivedKey
                onClientKey?(receivedKey)
                return receivedKey
            } catch SSAPError.rejected(let reason) {
                task.cancel()
                throw SSAPError.rejected(reason)
            } catch {
                task.cancel()
            }
        }
        throw SSAPError.cannotConnect
    }

    public func close() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        activeEndpoint = nil
        pointerHost = nil
        // URLSession temsilcisini (self) güçlü tutar; kapatılmazsa istemci hiç bırakılmaz.
        session.invalidateAndCancel()
    }

    public func launch(appId: String, params: [String: Any]) async throws {
        let response = try await request("ssap://system.launcher/launch", payload: ["id": appId, "params": params])
        if response["returnValue"] as? Bool == false { throw SSAPError.rejected(response["errorText"] as? String ?? "launch") }
    }

    public func foregroundAppId() async throws -> String {
        let response = try await request("ssap://com.webos.applicationManager/getForegroundAppInfo", payload: nil)
        return response["appId"] as? String ?? ""
    }

    /// LG webOS OLED'de 3 dakikalık saat ekran koruyucusunu kalıcı olarak engellemek için her döngüde taze bir
    /// kumanda giriş soketi açıp görünmez `YELLOW` tuş sinyali gönderir ve soketi temizce kapatır (LG TV boşta kalan
    /// pointer soketini kapattığı için önbelleğe alınan soket `CLOSE_WAIT`'te ölü kalıyordu). Ayrıca destekleyen
    /// modellerde `turnOffScreenSaver` servisini de tetikler. Hata fırlatmaz.
    public func keepScreenAwake() async {
        guard socket != nil else { return }

        // 1. Destekleniyorsa doğrudan tvpower servisiyle ekran koruyucu sayacını/ekranını sıfırla (desteklenmezse bir daha deneme).
        if turnOffScreenSaverSupported != false {
            do {
                let raw = try await request("ssap://com.webos.service.tvpower/power/turnOffScreenSaver", payload: nil)
                let ok = (raw["returnValue"] as? Bool) ?? true
                if turnOffScreenSaverSupported == nil {
                    turnOffScreenSaverSupported = ok
                    SubtitleLog.write("LG TV turnOffScreenSaver: \(ok ? "destekleniyor" : "reddedildi (\(raw["errorText"] ?? ""))")")
                }
            } catch {
                if turnOffScreenSaverSupported == nil {
                    turnOffScreenSaverSupported = false
                    SubtitleLog.write("LG TV turnOffScreenSaver desteklenmiyor: \(error)")
                }
            }
        }

        // 2. Taze pointer giriş soketi aç, görünmez YELLOW tuşu gönder, kısa süre olası ret çerçevesini dinle, sonra kapat.
        var task: URLSessionWebSocketTask?
        defer { task?.cancel(with: .normalClosure, reason: nil) }
        do {
            let fresh = try await openPointerSocket(allowPermissionUpgrade: true)
            task = fresh
            try await sendText(Self.keepAwakeCommand, on: fresh)
            let serverClose = await sniffImmediateClose(on: fresh)
            keepAwakeCount += 1
            if let serverClose {
                SubtitleLog.write("LG TV ekran koruyucu sinyali #\(keepAwakeCount) sonrası soket kapandı: \(serverClose)")
            } else if keepAwakeCount <= 5 {
                SubtitleLog.write("LG TV ekran koruyucu önlemi #\(keepAwakeCount): taze soketten sinyal gönderildi")
            }
        } catch {
            SubtitleLog.write("LG TV ekran koruyucu önlemi gönderilemedi: \(error)")
        }
    }

    /// Gönderimden hemen sonra LG TV soketi hata/yetki koduyla kapatıyorsa bunu yakalar; 120 ms sessizse
    /// soketi temizce kapatıp döner (`receive()` Task iptaline yanıt vermediği için kapatma burada yapılır).
    private func sniffImmediateClose(on task: URLSessionWebSocketTask) async -> String? {
        final class AtomicBool: @unchecked Sendable {
            private let lock = NSLock()
            private var flag = false
            var value: Bool {
                get { lock.withLock { flag } }
                set { lock.withLock { flag = newValue } }
            }
        }
        let timedOut = AtomicBool()
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    let msg = try await task.receive()
                    switch msg {
                    case .string(let s): return "msg=\(s)"
                    case .data(let d): return "bytes=\(d.count)"
                    @unknown default: return nil
                    }
                } catch {
                    if timedOut.value { return nil }
                    let code = task.closeCode.rawValue
                    let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    return "closeCode=\(code) reason=\(reason) err=\(error.localizedDescription)"
                }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return nil }
                timedOut.value = true
                task.cancel(with: .normalClosure, reason: nil)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - İç işleyiş

    private func openPointerSocket(allowPermissionUpgrade: Bool) async throws -> URLSessionWebSocketTask {
        let response: [String: Any]
        do {
            let raw = try await request("ssap://com.webos.service.networkinput/getPointerInputSocket", payload: nil)
            if raw["returnValue"] as? Bool == false {
                let code = raw["errorCode"].map { "\($0)" } ?? ""
                let text = raw["errorText"] as? String ?? ""
                throw SSAPError.rejected([code, text].filter { !$0.isEmpty }.joined(separator: " "))
            }
            response = raw
        } catch SSAPError.rejected(let reason) where allowPermissionUpgrade && Self.isPermissionError(reason) && !permissionUpgradeAttempted {
            permissionUpgradeAttempted = true
            SubtitleLog.write("LG TV ekran koruyucu önlemi: eski eşleşmede kumanda izni yok (\(reason)); TV'de tek seferlik onay isteniyor")
            try await upgradePermissions()
            return try await openPointerSocket(allowPermissionUpgrade: false)
        }
        guard let path = response["socketPath"] as? String, let url = URL(string: path) else {
            throw SSAPError.badResponse
        }
        pointerHost = url.host
        let task = session.webSocketTask(with: url)
        task.resume()
        return task
    }

    /// Eski client-key'de `CONTROL_MOUSE_AND_KEYBOARD` yoksa mevcut bağlantıyı bozmadan tek seferlik yeni onay ister.
    private func upgradePermissions() async throws {
        let targets = activeEndpoint.map { [$0] } ?? endpoints
        for url in targets {
            let upgraded = session.webSocketTask(with: url)
            upgraded.resume()
            do {
                try await sendRegistration(on: upgraded, clientKey: nil, forcePairing: true)
                let newKey = try await waitForRegistration(on: upgraded)
                socket?.cancel(with: .normalClosure, reason: nil)
                socket = upgraded
                activeEndpoint = url
                clientKey = newKey
                needsPermissionUpgrade = false
                onClientKey?(newKey)
                onPermissionsUpgraded?()
                SubtitleLog.write("LG TV ekran koruyucu önlemi: kumanda izni onaylandı ve kalıcı olarak kaydedildi")
                return
            } catch SSAPError.rejected(let reason) {
                upgraded.cancel()
                throw SSAPError.rejected(reason)
            } catch {
                upgraded.cancel()
            }
        }
        throw SSAPError.cannotConnect
    }

    static func isPermissionError(_ reason: String) -> Bool {
        let lower = reason.lowercased()
        return lower.contains("401")
            || lower.contains("permission")
            || lower.contains("insufficient")
            || lower.contains("unauthorized")
            || lower.contains("not registered")
    }

    /// Adres artık başka bir cihazdaysa bağlantı yanıtsız kalabilir; o adreste uzun süre beklenmez.
    private func sendRegistration(on task: URLSessionWebSocketTask, clientKey: String?, forcePairing: Bool = false) async throws {
        let message = String(decoding: SSAPMessages.register(clientKey: clientKey, forcePairing: forcePairing), as: UTF8.self)
        try await sendText(message, on: task)
    }

    private func sendText(_ text: String, on task: URLSessionWebSocketTask) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await task.send(.string(text)) }
            group.addTask { [handshakeTimeout] in
                try await Task.sleep(for: handshakeTimeout)
                task.cancel()
                throw SSAPError.cannotConnect
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// TV'deki izin sorusu yanıtlanana kadar bekler; `approvalTimeout` dolarsa vazgeçer.
    private func waitForRegistration(on task: URLSessionWebSocketTask) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                while true {
                    let message = try await Self.decode(task.receive())
                    switch message["type"] as? String {
                    case "registered":
                        guard let key = (message["payload"] as? [String: Any])?["client-key"] as? String else { throw SSAPError.badResponse }
                        return key
                    case "error":
                        throw SSAPError.rejected(message["error"] as? String ?? "register")
                    default:
                        continue // "response": TV soruyu gösterdi, onay bekleniyor
                    }
                }
            }
            group.addTask { [approvalTimeout] in
                try await Task.sleep(for: approvalTimeout)
                // receive() iptale yanıt vermez; soketi kapatmak onu da sonlandırır.
                task.cancel()
                throw SSAPError.rejected("timeout")
            }
            defer {
                group.cancelAll()
            }
            guard let key = try await group.next() else { throw SSAPError.badResponse }
            return key
        }
    }

    private func request(_ uri: String, payload: [String: Any]?) async throws -> [String: Any] {
        guard let socket else { throw SSAPError.cannotConnect }
        let id = "req_\(nextId)"
        nextId += 1
        let text = String(decoding: SSAPMessages.request(id: id, uri: uri, payload: payload), as: UTF8.self)
        let raw = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await socket.send(.string(text))
                while true {
                    let data = try await Self.rawData(socket.receive())
                    guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SSAPError.badResponse }
                    guard message["id"] as? String == id else { continue }
                    if message["type"] as? String == "error" { throw SSAPError.rejected(message["error"] as? String ?? uri) }
                    return data
                }
            }
            group.addTask { [handshakeTimeout] in
                try await Task.sleep(for: handshakeTimeout)
                socket.cancel()
                throw SSAPError.cannotConnect
            }
            defer { group.cancelAll() }
            guard let reply = try await group.next() else { throw SSAPError.badResponse }
            return reply
        }
        guard let message = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw SSAPError.badResponse }
        return message["payload"] as? [String: Any] ?? [:]
    }

    private static func rawData(_ message: URLSessionWebSocketTask.Message) throws -> Data {
        switch message {
        case .data(let d): return d
        case .string(let s): return Data(s.utf8)
        @unknown default: throw SSAPError.badResponse
        }
    }

    private static func decode(_ message: URLSessionWebSocketTask.Message) throws -> [String: Any] {
        let data = try rawData(message)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SSAPError.badResponse }
        return object
    }

    /// TV'nin 3001 portundaki sertifikası kendinden imzalıdır; yalnız bu TV'nin adresi için kabul edilir.
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let host = challenge.protectionSpace.host
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              (endpoints.contains(where: { $0.host == host }) || pointerHost == host),
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// TV uygulamasını açık tutar: TV kendi HDMI ya da yayın girişine geçerse (SimpLink/CEC) veya LG OLED ekran
/// koruyucusu açılırsa uygulamayı yeniden öne getirir; uygulama öndeyken düzenli görünmez donanım sinyaliyle
/// 3 dakikalık saat ekran koruyucusunun hiç başlamamasını sağlar.
public final class TVKeeper: @unchecked Sendable {
    private let connect: () async throws -> TVControlling
    private let appId: String
    private let params: [String: Any]
    private let appConnected: (@Sendable () -> Bool)?
    private let relaunchInterval: Duration
    private let keepAwakeInterval: Duration
    private var control: TVControlling?
    private var loop: Task<Void, Never>?
    private var lastLaunch: ContinuousClock.Instant?
    private var lastKeepAwake: ContinuousClock.Instant?
    private var lastForegroundApp: String?
    private var lastHDMIPort: Int?
    private let onHDMIPortDetected: (@Sendable (Int) -> Void)?

    /// `appConnected` verilirse (Samsung) TV'ye yalnız TV uygulaması bilgisayara bağlı değilken ve en çok
    /// `relaunchInterval`'da bir dokunulur: uygulama açılır, bağlantı hemen kapatılır. Samsung önplandaki uygulamayı
    /// söylemediği için sürekli açık "uzaktan kumanda" bağlantısı gereksizdi; birkaç saniyede bir yeniden kurulan
    /// bağlantı TV'de "uzaktan kumanda bağlandı" bildirimi çıkarıyor, PS5 kolunu düşürüyordu (#5).
    public init(connect: @escaping () async throws -> TVControlling, appId: String, params: [String: Any],
                appConnected: (@Sendable () -> Bool)? = nil, relaunchInterval: Duration = .seconds(30),
                keepAwakeInterval: Duration = .seconds(45), initialHDMIPort: Int? = nil,
                onHDMIPortDetected: (@Sendable (Int) -> Void)? = nil) {
        self.connect = connect
        self.appId = appId
        self.params = params
        self.appConnected = appConnected
        self.relaunchInterval = relaunchInterval
        self.keepAwakeInterval = keepAwakeInterval
        self.lastHDMIPort = initialHDMIPort.flatMap { (1...4).contains($0) ? $0 : nil }
        self.onHDMIPortDetected = onHDMIPortDetected
    }

    /// Kullanıcının bilerek açtığı uygulamalara (Netflix vb.) dokunulmaz; yalnız giriş ve yayın ekranları.
    static func isInputOrLiveTV(_ appId: String) -> Bool {
        appId.hasPrefix("com.webos.app.hdmi") || appId.hasPrefix("com.webos.app.externalinput") || appId == "com.webos.app.livetv"
    }

    /// `com.webos.app.hdmi3` / `com.webos.app.externalinput.hdmi3` gibi önplan uygulama kimliklerinden HDMI port
    /// numarasını (1–4) çıkarır. TV HDMI girişine geçip uygulama arka plana düştüğünde webOS eski `<video ext://hdmi>`
    /// katmanını bozduğu için yeniden açarken `hdmi` parametresiyle göndermek TV uygulamasında HDMI akışını tazeletir.
    static func hdmiPort(from appId: String) -> Int? {
        let lower = appId.lowercased()
        guard let range = lower.range(of: "hdmi", options: .backwards) else { return nil }
        let suffix = lower[range.upperBound...]
        guard let first = suffix.first, let port = Int(String(first)), (1...4).contains(port) else { return nil }
        return port
    }

    private func launchParams(hdmi: Int? = nil) -> [String: Any] {
        var merged = params
        if let port = hdmi ?? lastHDMIPort, merged["hdmi"] == nil {
            merged["hdmi"] = port
        }
        return merged
    }

    /// LG webOS OLED ekran koruyucu ve Always Ready ekranları.
    static func isScreensaver(_ appId: String) -> Bool {
        let lower = appId.lowercased()
        return lower.contains("screensaver") || lower.contains("alwaysready")
    }

    /// Bir kontrol. Hata fırlatmaz; bağlantı sorununda bir sonraki kontrolde yeniden dener.
    public func tick() async {
        if let appConnected {
            await launchIfAppIsAway(appConnected())
            return
        }
        do {
            if control == nil {
                let fresh = try await connect()
                control = fresh
                lastKeepAwake = nil
                try await fresh.launch(appId: appId, params: launchParams())
                return
            }
            guard let control else { return }
            let current = try await control.foregroundAppId()
            if current != lastForegroundApp {
                lastForegroundApp = current
                SubtitleLog.write("LG TV önplan uygulaması: \(current.isEmpty ? "(boş)" : current)")
            }
            if let port = Self.hdmiPort(from: current), port != lastHDMIPort {
                lastHDMIPort = port
                onHDMIPortDetected?(port)
            }
            if Self.isScreensaver(current) {
                SubtitleLog.write("LG TV ekran koruyucu algılandı (\(current)) — uygulama öne getiriliyor")
                await control.keepScreenAwake()
                try await control.launch(appId: appId, params: launchParams())
                lastKeepAwake = .now
            } else if Self.isInputOrLiveTV(current) {
                let port = Self.hdmiPort(from: current)
                if let port {
                    SubtitleLog.write("LG TV HDMI \(port) girişinden dönülüyor — HDMI \(port) yeniden bağlanacak")
                }
                try await control.launch(appId: appId, params: launchParams(hdmi: port))
            } else if current == appId {
                if lastKeepAwake == nil || ContinuousClock.now - lastKeepAwake! >= keepAwakeInterval {
                    await control.keepScreenAwake()
                    lastKeepAwake = .now
                }
            }
        } catch {
            control?.close()
            control = nil
            lastKeepAwake = nil
        }
    }

    private func launchIfAppIsAway(_ connected: Bool) async {
        guard !connected else { return }
        if let lastLaunch, ContinuousClock.now - lastLaunch < relaunchInterval { return }
        lastLaunch = .now
        guard let fresh = try? await connect() else { return }
        defer { fresh.close() }
        try? await fresh.launch(appId: appId, params: params)
    }

    public func start(interval: Duration = .seconds(5)) {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Mac uykudan uyandığında: bağlantıyı yenile.
    public func reconnect() {
        control?.close()
        control = nil
        lastLaunch = nil
        lastKeepAwake = nil
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        control?.close()
        control = nil
        lastKeepAwake = nil
    }

    deinit { loop?.cancel() }
}
