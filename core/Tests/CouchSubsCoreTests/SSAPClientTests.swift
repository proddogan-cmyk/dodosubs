// SPDX-License-Identifier: AGPL-3.0-only

import Network
import XCTest
@testable import CouchSubsCore

/// SSAP konuşan sahte bir TV: register'a client-key ile, isteklere sırayla verilen yanıtlarla döner.
final class FakeLGTV: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-lgtv")
    private(set) var receivedURIs: [String] = []
    private(set) var receivedPayloads: [[String: Any]] = []
    private(set) var registerPayloads: [[String: Any]] = []
    var foregroundApps: [String] = []
    /// true ise register'a yalnız "soru gösterildi" yanıtı verir, onay hiç gelmez.
    var neverApprove = false
    /// `getPointerInputSocket` çağrısında dönecek soket yolu.
    var pointerSocketPath: String?
    /// true ise ilk `getPointerInputSocket` isteğini 401 yetki hatasıyla reddeder, sonraki kayıtta `upgradedKey` verir.
    var requirePermissionUpgrade = false
    var issuedKeys: [String] = []
    private var upgraded = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async -> UInt16 {
        await withCheckedContinuation { continuation in
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.receive(on: connection)
            }
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state { continuation.resume(returning: listener.port!.rawValue) }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil, let data else { return }
            // Gerçek LG TV ikili çerçeveyi reddeder; yalnız metin çerçevesi kabul edilir.
            let frame = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            guard frame?.opcode == .text else {
                self.send(["type": "error", "id": "", "error": "400 binary messages not supported", "payload": [:]], on: connection)
                return self.receive(on: connection)
            }
            guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            self.handle(message, on: connection)
            self.receive(on: connection)
        }
    }

    private func handle(_ message: [String: Any], on connection: NWConnection) {
        let id = message["id"] as? String ?? ""
        if message["type"] as? String == "register" {
            let regPayload = message["payload"] as? [String: Any] ?? [:]
            registerPayloads.append(regPayload)
            if regPayload["forcePairing"] as? Bool == true { upgraded = true }
            let key = issuedKeys.isEmpty ? (upgraded ? "upgraded-key" : "fake-key") : issuedKeys.removeFirst()
            send(["type": "response", "id": id, "payload": ["pairingType": "PROMPT", "returnValue": true]], on: connection)
            if !neverApprove { send(["type": "registered", "id": id, "payload": ["client-key": key]], on: connection) }
            return
        }
        let uri = message["uri"] as? String ?? ""
        receivedURIs.append(uri)
        receivedPayloads.append(message["payload"] as? [String: Any] ?? [:])
        if uri.hasSuffix("getPointerInputSocket") {
            if requirePermissionUpgrade && !upgraded {
                send(["type": "error", "id": id, "error": "401 insufficient permissions", "payload": [:]], on: connection)
                return
            }
            var payload: [String: Any] = ["returnValue": true]
            if let pointerSocketPath { payload["socketPath"] = pointerSocketPath }
            send(["type": "response", "id": id, "payload": payload], on: connection)
            return
        }
        var payload: [String: Any] = ["returnValue": true]
        if uri.hasSuffix("getForegroundAppInfo") {
            payload["appId"] = foregroundApps.isEmpty ? "" : foregroundApps.removeFirst()
        }
        send(["type": "response", "id": id, "payload": payload], on: connection)
    }

    private func send(_ object: [String: Any], on connection: NWConnection) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}

final class SSAPClientTests: XCTestCase {
    func testConnectReturnsClientKeyAndLaunchSendsUri() async throws {
        let tv = try FakeLGTV()
        let port = await tv.start()
        defer { tv.stop() }

        let client = SSAPClient(endpoints: [URL(string: "ws://127.0.0.1:\(port)")!], clientKey: nil)
        let key = try await client.connect()
        XCTAssertEqual(key, "fake-key")

        try await client.launch(appId: "com.couchsubs.tv", params: ["server": "http://1.2.3.4:8787"])
        XCTAssertEqual(tv.receivedURIs.last, "ssap://system.launcher/launch")
        XCTAssertEqual(tv.receivedPayloads.last?["id"] as? String, "com.couchsubs.tv")
        client.close()
    }

    func testForegroundAppId() async throws {
        let tv = try FakeLGTV()
        tv.foregroundApps = ["com.webos.app.hdmi2"]
        let port = await tv.start()
        defer { tv.stop() }

        let client = SSAPClient(endpoints: [URL(string: "ws://127.0.0.1:\(port)")!], clientKey: "fake-key")
        _ = try await client.connect()
        let app = try await client.foregroundAppId()
        XCTAssertEqual(app, "com.webos.app.hdmi2")
        client.close()
    }

    func testUnansweredPairingPromptTimesOut() async throws {
        let tv = try FakeLGTV()
        tv.neverApprove = true
        let port = await tv.start()
        defer { tv.stop() }

        let client = SSAPClient(endpoints: [URL(string: "ws://127.0.0.1:\(port)")!], clientKey: nil, approvalTimeout: .seconds(1))
        let begin = Date()
        do {
            _ = try await client.connect()
            XCTFail("Onaysız eşleşme başarılı olmamalı")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(begin), 5)
    }

    func testEndpointThatNeverAnswersIsAbandonedQuickly() async throws {
        // Adres artık başka bir cihazdaysa TCP kabul edilip yanıt gelmeyebilir; yeniden arama gecikmesin.
        let silent = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "silent")
        var held: [NWConnection] = []
        silent.newConnectionHandler = { connection in queue.async { held.append(connection); connection.start(queue: queue) } }
        let ready = expectation(description: "dinliyor")
        silent.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        silent.start(queue: queue)
        await fulfillment(of: [ready], timeout: 3)
        defer { silent.cancel() }

        let client = SSAPClient(endpoints: [URL(string: "ws://127.0.0.1:\(silent.port!.rawValue)")!], clientKey: "k",
                                handshakeTimeout: .milliseconds(300))
        let begin = Date()
        do {
            _ = try await client.connect()
            XCTFail("Yanıtsız adres başarılı olmamalı")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(begin), 3)
        client.close()
    }

    func testFallsBackToNextEndpoint() async throws {
        let tv = try FakeLGTV()
        let port = await tv.start()
        defer { tv.stop() }

        // İlk adreste kimse dinlemiyor; ikinciye düşmeli.
        let client = SSAPClient(endpoints: [URL(string: "ws://127.0.0.1:1")!, URL(string: "ws://127.0.0.1:\(port)")!], clientKey: nil)
        let key = try await client.connect()
        XCTAssertEqual(key, "fake-key")
        client.close()
    }

    func testKeepScreenAwakeOpensFreshPointerSocketPerPulse() async throws {
        let pointer = try FakePointerSocket()
        let pointerPort = await pointer.start()
        defer { pointer.stop() }

        let tv = try FakeLGTV()
        tv.pointerSocketPath = "ws://127.0.0.1:\(pointerPort)/netinput.pointer.sock"
        let port = await tv.start()
        defer { tv.stop() }

        let client = SSAPClient(endpoints: [URL(string: "ws://127.0.0.1:\(port)")!], clientKey: "fake-key")
        _ = try await client.connect()

        await client.keepScreenAwake()
        await client.keepScreenAwake()
        let commands = await pointer.waitForMessages(count: 2)

        XCTAssertEqual(commands, [SSAPClient.keepAwakeCommand, SSAPClient.keepAwakeCommand])
        let pointerRequests = tv.receivedURIs.filter { $0.hasSuffix("getPointerInputSocket") }
        XCTAssertEqual(pointerRequests.count, 2, "her canlılık sinyali ölü CLOSE_WAIT soket bırakmadan taze soket açmalı")
        client.close()
    }

    func testNeedsPermissionUpgradeForcesPairingOnceAndMarksUpgraded() async throws {
        let tv = try FakeLGTV()
        let port = await tv.start()
        defer { tv.stop() }

        let savedKeys = KeyBox()
        let upgradedFlag = Flag()
        let client = SSAPClient(endpoints: [URL(string: "ws://127.0.0.1:\(port)")!], clientKey: "legacy-key",
                                needsPermissionUpgrade: true,
                                onClientKey: { savedKeys.append($0) },
                                onPermissionsUpgraded: { upgradedFlag.value = true })
        let key = try await client.connect()

        XCTAssertEqual(key, "upgraded-key")
        XCTAssertEqual(savedKeys.values.last, "upgraded-key")
        XCTAssertTrue(upgradedFlag.value)
        XCTAssertEqual(tv.registerPayloads.first?["forcePairing"] as? Bool, true)
        XCTAssertNil(tv.registerPayloads.first?["client-key"])
        client.close()
    }

    func testKeepScreenAwakeUpgradesLegacyKeyOn401AndPersistsNewKey() async throws {
        let pointer = try FakePointerSocket()
        let pointerPort = await pointer.start()
        defer { pointer.stop() }

        let tv = try FakeLGTV()
        tv.pointerSocketPath = "ws://127.0.0.1:\(pointerPort)/netinput.pointer.sock"
        tv.requirePermissionUpgrade = true
        let port = await tv.start()
        defer { tv.stop() }

        let savedKeys = KeyBox()
        let client = SSAPClient(endpoints: [URL(string: "ws://127.0.0.1:\(port)")!], clientKey: "legacy-key",
                                onClientKey: { savedKeys.append($0) })
        _ = try await client.connect()
        await client.keepScreenAwake()
        let commands = await pointer.waitForMessages(count: 1)

        XCTAssertEqual(commands, [SSAPClient.keepAwakeCommand])
        XCTAssertEqual(savedKeys.values.last, "upgraded-key")
        XCTAssertEqual(tv.registerPayloads.last?["forcePairing"] as? Bool, true)
        client.close()
    }
}

/// LG'nin pointer giriş WebSocket'ini taklit eder ve gelen metin komutlarını kaydeder.
private final class FakePointerSocket: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-pointer")
    private let lock = NSLock()
    private var messages: [String] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async -> UInt16 {
        await withCheckedContinuation { continuation in
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.receive(on: connection)
            }
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state { continuation.resume(returning: listener.port!.rawValue) }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    func waitForMessages(count: Int) async -> [String] {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            let current = lock.withLock { messages }
            if current.count >= count { return current }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return lock.withLock { messages }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { return }
            let text = String(decoding: data, as: UTF8.self)
            self.lock.withLock { self.messages.append(text) }
            self.receive(on: connection)
        }
    }
}

private final class KeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ key: String) { lock.withLock { stored.append(key) } }
    var values: [String] { lock.withLock { stored } }
}

final class TVKeeperTests: XCTestCase {
    final class FakeControl: TVControlling, @unchecked Sendable {
        var foreground: [String]
        var launches: [(String, [String: String])] = []
        var rawLaunches: [(String, [String: Any])] = []
        var failNext = false
        var closes = 0
        var keepAwakes = 0
        init(foreground: [String]) { self.foreground = foreground }
        func close() { closes += 1 }
        func keepScreenAwake() async { keepAwakes += 1 }
        func foregroundAppId() async throws -> String {
            if failNext { failNext = false; throw URLError(.networkConnectionLost) }
            return foreground.isEmpty ? "com.couchsubs.tv" : foreground.removeFirst()
        }
        func launch(appId: String, params: [String: Any]) async throws {
            launches.append((appId, params.compactMapValues { $0 as? String }))
            rawLaunches.append((appId, params))
        }
    }

    func testRelaunchesOnlyWhenHdmiInputIsInFront() async throws {
        let control = FakeControl(foreground: ["com.couchsubs.tv", "com.webos.app.hdmi2", "com.couchsubs.tv", "netflix"])
        let keeper = TVKeeper(connect: { control }, appId: "com.couchsubs.tv", params: ["server": "http://1.2.3.4:8787"])
        await keeper.tick()   // bağlanır ve uygulamayı bir kez başlatır
        await keeper.tick()   // önde HDMI girişi → geri getir
        await keeper.tick()   // önde bizimki
        await keeper.tick()   // kullanıcı Netflix'i açtı → dokunma
        XCTAssertEqual(control.launches.count, 2)
        XCTAssertEqual(control.launches.last?.0, "com.couchsubs.tv")
        XCTAssertEqual(control.launches.last?.1["server"], "http://1.2.3.4:8787")
    }

    func testReconnectsWhenTVWasOffOrConnectionDropped() async throws {
        struct Off: Error {}
        let control = FakeControl(foreground: [])
        var attempts = 0
        let keeper = TVKeeper(connect: {
            attempts += 1
            if attempts == 1 { throw Off() }   // TV kapalı
            return control
        }, appId: "com.couchsubs.tv", params: [:])
        await keeper.tick()
        XCTAssertTrue(control.launches.isEmpty)
        await keeper.tick()                     // TV açıldı → bağlan ve başlat
        XCTAssertEqual(control.launches.count, 1)

        control.failNext = true                 // bağlantı koptu
        await keeper.tick()
        await keeper.tick()                     // yeniden bağlanır ve tekrar başlatır
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(control.launches.count, 2)
        XCTAssertEqual(control.closes, 1, "kopan bağlantı kapatılır")
    }

    func testSamsungIsLeftAloneWhileTheAppIsConnected() async throws {
        let control = FakeControl(foreground: [])
        let connected = Flag()
        var connects = 0
        let keeper = TVKeeper(connect: { connects += 1; return control }, appId: "com.couchsubs.tv", params: [:],
                              appConnected: { connected.value }, relaunchInterval: .milliseconds(200))
        await keeper.tick()                     // uygulama bağlı değil → aç ve bağlantıyı kapat
        XCTAssertEqual(control.launches.count, 1)
        XCTAssertEqual(control.closes, 1)
        await keeper.tick()                     // hemen yeniden açmaya çalışmaz
        XCTAssertEqual(connects, 1)
        connected.value = true
        try await Task.sleep(for: .milliseconds(250))
        for _ in 0..<5 { await keeper.tick() }  // uygulama bağlıyken TV'ye hiç dokunulmaz
        XCTAssertEqual(connects, 1)
        connected.value = false
        await keeper.tick()                     // uygulama kapandı → bir kez daha aç
        XCTAssertEqual(control.launches.count, 2)
    }

    func testKeepsScreenAwakePeriodicallyAndRescuesFromScreensaver() async throws {
        let control = FakeControl(foreground: [
            "com.couchsubs.tv",
            "com.couchsubs.tv",
            "netflix",
            "com.webos.app.screensaver",
            "com.webos.app.alwaysready",
        ])
        let keeper = TVKeeper(connect: { control }, appId: "com.couchsubs.tv", params: ["server": "http://1.2.3.4:8787"],
                              keepAwakeInterval: .milliseconds(150))
        await keeper.tick()                     // bağlan ve başlat (launch #1)
        await keeper.tick()                     // önde bizimki → ilk canlılık sinyali (awake #1)
        XCTAssertEqual(control.keepAwakes, 1)

        await keeper.tick()                     // aralık dolmadı → hemen tekrar göndermez
        XCTAssertEqual(control.keepAwakes, 1)

        try await Task.sleep(for: .milliseconds(180))
        await keeper.tick()                     // Netflix önde → ne sinyal ne yeniden açma
        XCTAssertEqual(control.keepAwakes, 1)
        XCTAssertEqual(control.launches.count, 1)

        await keeper.tick()                     // ekran koruyucu → uyandır (awake #2) ve geri getir (launch #2)
        XCTAssertEqual(control.keepAwakes, 2)
        XCTAssertEqual(control.launches.count, 2)

        await keeper.tick()                     // Always Ready → uyandır (awake #3) ve geri getir (launch #3)
        XCTAssertEqual(control.keepAwakes, 3)
        XCTAssertEqual(control.launches.count, 3)
    }

    func testPassesDetectedHdmiPortOnRelaunchToPreventBlackScreen() async throws {
        XCTAssertEqual(TVKeeper.hdmiPort(from: "com.webos.app.hdmi3"), 3)
        XCTAssertEqual(TVKeeper.hdmiPort(from: "com.webos.app.externalinput.hdmi2"), 2)
        XCTAssertNil(TVKeeper.hdmiPort(from: "com.couchsubs.tv"))
        XCTAssertNil(TVKeeper.hdmiPort(from: "com.webos.app.livetv"))

        let control = FakeControl(foreground: [
            "com.webos.app.hdmi3",
            "com.webos.app.screensaver",
        ])
        let keeper = TVKeeper(connect: { control }, appId: "com.couchsubs.tv", params: ["server": "http://1.2.3.4:8787"])
        await keeper.tick()                     // ilk açılış
        await keeper.tick()                     // HDMI 3'ten dönüş → hdmi=3 gönderir
        XCTAssertEqual(control.rawLaunches.count, 2)
        XCTAssertEqual(control.rawLaunches[1].1["hdmi"] as? Int, 3)

        await keeper.tick()                     // ekran koruyucudan dönüş → bilinen hdmi=3 korunur
        XCTAssertEqual(control.rawLaunches.count, 3)
        XCTAssertEqual(control.rawLaunches[2].1["hdmi"] as? Int, 3)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
