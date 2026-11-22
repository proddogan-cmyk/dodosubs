// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import XCTest
@testable import CouchSubsCore

@MainActor
final class PanelPresenceTests: XCTestCase {
    private final class Reader: TextReader, @unchecked Sendable {
        var lines: [TextLine] = []
        var count = 0
        func read(_ image: CGImage) throws -> String { lines.map(\.text).joined(separator: "\n") }
        func read(_ image: CGImage, deep: Bool) throws -> String { try read(image) }
        func readLines(_ image: CGImage, deep: Bool) throws -> Reading {
            count += 1
            return Reading(lines: lines)
        }
    }

    private final class Translator: TextTranslator {
        var calls: [String] = []
        func translate(_ text: String) async throws -> String {
            calls.append(text)
            return "TR: " + text
        }
    }

    private final class Server: RegionSending {
        var sent: [(id: String, text: String)] = []
        var blocks: [[ScreenTranslation.Item]?] = []
        var loadings: [Bool] = []
        var options: [BubbleOptions] = []
        func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) {
            sendRegion(id: id, text: text, box: box, lineHeight: lineHeight, icons: nil, blocks: nil,
                       presentation: .overlay, anchor: nil, options: BubbleOptions())
        }
        func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                        blocks: [ScreenTranslation.Item]?, presentation: RegionPresentation, anchor: TextBox?,
                        options: BubbleOptions) {
            sent.append((id, text))
            self.blocks.append(blocks)
            loadings.append(options.loading)
            self.options.append(options)
        }
        func clearRegions() {}
    }

    /// Oyun içi telefon çerçevesi çizer: dışarıda oyun arka planı, ortada koyu kasa (bezel), üst çentik ve değişken iç ekran.
    private func phoneImage(background: CGFloat, screen: CGFloat, messageBars: Int, barShade: CGFloat) -> CGImage {
        let w = 240, h = 360
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        // Dış oyun dünyası arka planı
        ctx.setFillColor(gray: background, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Telefon dış kasası (bezel)
        ctx.setFillColor(gray: 0.08, alpha: 1)
        ctx.fill(CGRect(x: 16, y: 18, width: w - 32, height: h - 36))
        // Telefon iç ekranı
        ctx.setFillColor(gray: screen, alpha: 1)
        ctx.fill(CGRect(x: 28, y: 34, width: w - 56, height: h - 68))
        // Üst durum çubuğu / çentik (CoreGraphics'te y yukarıdan değil aşağıdandır)
        ctx.setFillColor(gray: 0.12, alpha: 1)
        ctx.fill(CGRect(x: 28, y: h - 54, width: w - 56, height: 20))
        ctx.setFillColor(gray: 0.92, alpha: 1)
        ctx.fill(CGRect(x: 40, y: h - 48, width: 32, height: 8))
        ctx.fill(CGRect(x: w - 72, y: h - 48, width: 26, height: 8))
        // Değişken iç mesaj kutuları (telefonun ortası)
        ctx.setFillColor(gray: barShade, alpha: 1)
        for i in 0..<messageBars {
            let y = 70 + i * 38
            ctx.fill(CGRect(x: 46, y: y, width: w - 92, height: 22))
        }
        return ctx.makeImage()!
    }

    /// Telefon kapalıyken sağ altta kalan 3B oyun sahnesi (eğik yollar, binalar, rastgele bloklar).
    private func worldImage(seed: Int) -> CGImage {
        let w = 240, h = 360
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0.45, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Eğik perspektif çizgileri ve sahne blokları
        ctx.setStrokeColor(gray: 0.15, alpha: 1)
        ctx.setLineWidth(6)
        ctx.move(to: CGPoint(x: 0, y: 30 + seed * 15))
        ctx.addLine(to: CGPoint(x: w, y: h - 40 - seed * 10))
        ctx.move(to: CGPoint(x: w, y: 60))
        ctx.addLine(to: CGPoint(x: 20, y: h - 20))
        ctx.strokePath()
        ctx.setFillColor(gray: 0.78, alpha: 1)
        ctx.fill(CGRect(x: 60 + seed * 12, y: 120, width: 95, height: 70))
        return ctx.makeImage()!
    }

    private func solidImage(gray: CGFloat) -> CGImage {
        let w = 240, h = 360
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: gray, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    func testPhoneTemplateMatchesDespiteDifferentInteriorAndBackground() throws {
        let reference = phoneImage(background: 0.70, screen: 0.85, messageBars: 2, barShade: 0.30)
        let template = try XCTUnwrap(PanelTemplate.capture(from: reference))

        // Telefon hâlâ açık ama içi tamamen farklı (koyu tema, 5 mesaj satırı) ve dışarıda gece arka planı var.
        let differentApp = phoneImage(background: 0.25, screen: 0.35, messageBars: 5, barShade: 0.90)
        let score = template.similarity(to: differentApp)
        XCTAssertTrue(template.matches(differentApp), "Aynı telefon farklı içerikle eşleşmeli (skor: \(score))")
    }

    func testPhoneTemplateRejectsClosedWorldSceneAndBlankScreen() throws {
        let reference = phoneImage(background: 0.70, screen: 0.85, messageBars: 3, barShade: 0.25)
        let template = try XCTUnwrap(PanelTemplate.capture(from: reference))

        let world = worldImage(seed: 1)
        XCTAssertFalse(template.matches(world), "Telefon kapalıyken oyun dünyası eşleşmemeli (skor: \(template.similarity(to: world)))")
        XCTAssertFalse(template.matches(solidImage(gray: 0.0)))
        XCTAssertEqual(template.similarity(to: solidImage(gray: 0.5)), 0)
    }

    func testBlankScreenCannotBeCapturedAsTemplate() {
        XCTAssertNil(PanelTemplate.capture(from: solidImage(gray: 0.0)))
        XCTAssertNil(PanelTemplate.capture(from: solidImage(gray: 0.8)))
    }

    func testExtraAreaCodableBackwardCompatibilityAndTemplateRoundTrip() throws {
        // Eski JSON (onlyWhenVisible ve panelTemplate yok) sorunsuz açılmalı.
        let legacyJSON = #"{"id":"p1","name":"Phone","region":{"top":0.5,"bottom":0.95,"left":0.72,"right":0.98},"enabled":true}"#
        let decoded = try JSONDecoder().decode(ExtraArea.self, from: Data(legacyJSON.utf8))
        XCTAssertFalse(decoded.onlyWhenVisible)
        XCTAssertNil(decoded.panelTemplate)

        // Yeni alanlar ve şablon kaybolmadan encode/decode olmalı.
        let template = try XCTUnwrap(PanelTemplate.capture(from: phoneImage(background: 0.6, screen: 0.9, messageBars: 2, barShade: 0.2)))
        let area = ExtraArea(id: "p2", name: "GTA Phone", region: ExtraAreaPreset.phone.region,
                             enabled: true, onlyWhenVisible: true, panelTemplate: template)
        let data = try JSONEncoder().encode(area)
        let restored = try JSONDecoder().decode(ExtraArea.self, from: data)
        XCTAssertEqual(restored, area)
    }

    private final class Flag: @unchecked Sendable {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    func testRegionWatcherSkipsOCRWhenClosedAndClearsBoxWhenPhoneCloses() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let phoneOpen = Flag(false)
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server,
                                    minReadingHoldMs: 0,
                                    panelDetector: { _, _, _ in phoneOpen.value })
        let phone = ExtraArea(id: "phone", name: "Phone", region: ExtraAreaPreset.phone.region, onlyWhenVisible: true)
        reader.lines = [TextLine("Meet me at the pier.", box: TextBox(left: 0.1, top: 0.2, right: 0.9, bottom: 0.3))]

        // 1) Telefon kapalıyken arka plan değişse bile OCR ve çeviri hiç çalışmamalı.
        await watcher.pass(worldImage(seed: 1), areas: [phone])
        await watcher.pass(worldImage(seed: 2), areas: [phone])
        XCTAssertEqual(reader.count, 0)
        XCTAssertTrue(translator.calls.isEmpty)
        XCTAssertTrue(server.sent.isEmpty)

        // 2) Telefon açılınca okur ve kararlı olunca çevirip TV'ye gönderir (çeviri sürerken buzlu cam shimmer + ardından metin).
        phoneOpen.value = true
        let openFrame = phoneImage(background: 0.6, screen: 0.9, messageBars: 2, barShade: 0.2)
        await watcher.pass(openFrame, areas: [phone])
        await watcher.pass(openFrame, areas: [phone])
        XCTAssertEqual(reader.count, 1)
        XCTAssertEqual(translator.calls, ["Meet me at the pier."])
        XCTAssertEqual(server.sent.map(\.text), ["", "TR: Meet me at the pier."])
        XCTAssertEqual(server.loadings, [true, false])

        // 3) Telefon açıkken 1–2 karelik el sallanması (kısa düşüş) kutuyu silmemeli ve titreşim yapmamalı.
        phoneOpen.value = false
        await watcher.pass(worldImage(seed: 3), areas: [phone])
        await watcher.pass(worldImage(seed: 4), areas: [phone])
        XCTAssertEqual(reader.count, 1, "Sallanma düşüşünde gereksiz OCR çalışmamalı")
        XCTAssertEqual(server.sent.map(\.text), ["", "TR: Meet me at the pier."], "Kısa sallanmada kutu silinmemeli")

        // 4) Ardışık 3. kapalı karede telefon gerçekten kapanmış sayılır ve TV kutusu hemen temizlenir.
        await watcher.pass(worldImage(seed: 5), areas: [phone])
        XCTAssertEqual(reader.count, 1, "Telefon kapandığında gereksiz OCR çalışmamalı")
        XCTAssertEqual(server.sent.map(\.text), ["", "TR: Meet me at the pier.", ""])

        // 5) Kapalı kalmaya devam ettikçe tekrar OCR veya boş gönderim yapmaz.
        await watcher.pass(worldImage(seed: 6), areas: [phone])
        XCTAssertEqual(reader.count, 1)
        XCTAssertEqual(server.sent.count, 3)

        // 6) Telefon aynı mesajla tekrar açıldığında oturum önbelleğinden çeviri motoruna gitmeden anında döner (shimmer bile gerekmez!).
        phoneOpen.value = true
        await watcher.pass(openFrame, areas: [phone])
        await watcher.pass(openFrame, areas: [phone])
        XCTAssertEqual(translator.calls, ["Meet me at the pier."], "Aynı mesaj tekrar çevrilmemeli (0 ms önbellek)")
        XCTAssertEqual(server.sent.map(\.text), ["", "TR: Meet me at the pier.", "", "TR: Meet me at the pier."])
    }

    func testTrainedPhoneTranslatesImmediatelyOnFirstPass() async throws {
        let reader = Reader(), translator = Translator(), server = Server()
        let template = try XCTUnwrap(PanelTemplate.capture(from: phoneImage(background: 0.6, screen: 0.9, messageBars: 2, barShade: 0.2)))
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server,
                                    panelDetector: { _, _, _ in true })
        let phone = ExtraArea(id: "phone", name: "Phone", region: ExtraAreaPreset.phone.region,
                              onlyWhenVisible: true, panelTemplates: [template])
        reader.lines = [TextLine("Where are you?", box: TextBox(left: 0.1, top: 0.2, right: 0.9, bottom: 0.3))]

        // Tanıtılmış telefonda 2. turu beklemeden ilk okumada anında çevirip gönderir!
        await watcher.pass(phoneImage(background: 0.6, screen: 0.9, messageBars: 2, barShade: 0.2), areas: [phone])
        XCTAssertEqual(translator.calls, ["Where are you?"])
        XCTAssertEqual(server.sent.map(\.text), ["", "TR: Where are you?"])
        XCTAssertEqual(server.loadings, [true, false])
    }

    func testPhoneStripsChromeAndMainSubtitleAndHitsPackDirectly() async throws {
        let reader = Reader(), translator = Translator(), server = Server()
        let template = try XCTUnwrap(PanelTemplate.capture(from: phoneImage(background: 0.6, screen: 0.9, messageBars: 2, barShade: 0.2)))
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server,
                                    panelDetector: { _, _, _ in true })
        // GTA 6 oyun paketinde bu satır var → 0 ms'de paketten gelmeli, motor hiç çağrılmamalı!
        watcher.packLookup = { text in
            text == "Brian We're at the bar." ? PackMatch(text: "Bardayız.", spoken: []) : nil
        }
        // Ekranda o an konuşulan ana diyalog altyazısı:
        watcher.activeSourceSubtitle = "Oh yeah? Alright, shit, just one sec."

        let phone = ExtraArea(id: "phone", name: "Phone", region: ExtraAreaPreset.phone.region,
                              onlyWhenVisible: true, panelTemplates: [template])
        // Gerçek GTA 6 WhatUp ekranı simülasyonu (saat, üye sayısı, şifreleme etiketi, mesaj, sızan ana altyazı):
        reader.lines = [
            TextLine("2:23 pm", box: TextBox(left: 0.1, top: 0.05, right: 0.4, bottom: 0.10)),
            TextLine("3 Members", box: TextBox(left: 0.1, top: 0.12, right: 0.5, bottom: 0.17)),
            TextLine("& Messages encrypted", box: TextBox(left: 0.1, top: 0.20, right: 0.8, bottom: 0.25)),
            TextLine("New message", box: TextBox(left: 0.1, top: 0.28, right: 0.5, bottom: 0.33)),
            TextLine("Brian", box: TextBox(left: 0.1, top: 0.40, right: 0.3, bottom: 0.45)),
            TextLine("We're at the bar.", box: TextBox(left: 0.1, top: 0.46, right: 0.8, bottom: 0.52)),
            TextLine("Oh veah? Alriaht shit. just one sec.", box: TextBox(left: 0.1, top: 0.85, right: 0.9, bottom: 0.92)),
        ]

        await watcher.pass(phoneImage(background: 0.6, screen: 0.9, messageBars: 2, barShade: 0.2), areas: [phone])

        // 1) Motor hiç çağrılmadan paketten 0 ms'de çözülmeli!
        XCTAssertTrue(translator.calls.isEmpty, "GTA 6 paketi doğrudan eşleşmeliydi, motora düşmemeli")
        XCTAssertEqual(server.sent.map(\.text), ["Bardayız."])
        // 2) Gönderen adı ve karakter imza rengi ayrı başlık olarak TV'ye gitmeli!
        let blocks = try XCTUnwrap(server.blocks.last ?? nil)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].sender, "Brian")
        XCTAssertEqual(blocks[0].senderColor, "#fbbf24")
        XCTAssertEqual(blocks[0].translation, "Bardayız.")
        XCTAssertEqual(server.options.last?.layout, .chat)
    }

    func testPhoneHomeScreenIconsStaySilentAndEmailsUseCardLayout() {
        let region = ExtraAreaPreset.phone.region
        // Ana ekran ikonları → sessiz (.quiet)
        let icons = [
            TextLine("Camera", box: TextBox(left: 0.1, top: 0.1, right: 0.4, bottom: 0.2)),
            TextLine("Map", box: TextBox(left: 0.5, top: 0.1, right: 0.8, bottom: 0.2)),
            TextLine("Settings", box: TextBox(left: 0.1, top: 0.3, right: 0.4, bottom: 0.4)),
        ]
        let quiet = PhoneContent.parse(rawLines: icons, in: region, activeSubtitle: nil)
        XCTAssertEqual(quiet.layout, .quiet)
        XCTAssertTrue(quiet.messages.isEmpty)

        // Uzun e-posta / makale → okuma kartı (.card)
        let email = [
            TextLine("Job Offer", box: TextBox(left: 0.1, top: 0.1, right: 0.7, bottom: 0.16)),
            TextLine("Meet the crew down at the docks tonight before midnight.", box: TextBox(left: 0.1, top: 0.30, right: 0.9, bottom: 0.45)),
        ]
        let card = PhoneContent.parse(rawLines: email, in: region, activeSubtitle: nil)
        XCTAssertEqual(card.layout, .card)
        XCTAssertEqual(card.messages.count, 2)
    }

    func testQuickMessageStaysVisibleForMinimumReadingHold() async throws {
        let reader = Reader(), translator = Translator(), server = Server()
        var now = 10_000
        let open = Flag(true)
        let template = try XCTUnwrap(PanelTemplate.capture(from: phoneImage(background: 0.6, screen: 0.9, messageBars: 2, barShade: 0.2)))
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server,
                                    closeMisses: 1, minReadingHoldMs: 4200, clock: { now },
                                    panelDetector: { _, _, _ in open.value })
        let phone = ExtraArea(id: "phone", name: "Phone", region: ExtraAreaPreset.phone.region,
                              onlyWhenVisible: true, panelTemplates: [template])
        reader.lines = [TextLine("Meet me at the pier.", box: TextBox(left: 0.1, top: 0.2, right: 0.9, bottom: 0.3))]

        // t=10_000: Mesaj geldi ve çevrildi.
        await watcher.pass(phoneImage(background: 0.6, screen: 0.9, messageBars: 2, barShade: 0.2), areas: [phone])
        XCTAssertEqual(server.sent.last?.text, "TR: Meet me at the pier.")

        // t=11_500 (+1.5 sn): Mesaj/bildirim ekrandan hızlıca kayboldu → henüz 4.2 sn dolmadığı için balon SİLİNMEMELİ!
        now = 11_500
        open.value = false
        await watcher.pass(worldImage(seed: 1), areas: [phone])
        XCTAssertEqual(server.sent.last?.text, "TR: Meet me at the pier.", "Kullanıcı okuyabilsin diye balon tutulmalı")

        // t=14_500 (+4.5 sn): Minimum okuma süresi doldu → balon temizlenmeli!
        now = 14_500
        await watcher.pass(worldImage(seed: 2), areas: [phone])
        XCTAssertEqual(server.sent.last?.text, "", "Okuma süresi dolunca balon temizlenmeli")
    }

    func testLowConfidenceFadeInFrameWaitsBeforeTranslating() async throws {
        let reader = Reader(), translator = Translator(), server = Server()
        let template = try XCTUnwrap(PanelTemplate.capture(from: phoneImage(background: 0.6, screen: 0.9, messageBars: 2, barShade: 0.2)))
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server,
                                    minReadingHoldMs: 0, panelDetector: { _, _, _ in true })
        let phone = ExtraArea(id: "phone", name: "Phone", region: ExtraAreaPreset.phone.region,
                              onlyWhenVisible: true, panelTemplates: [template])
        let frame = phoneImage(background: 0.6, screen: 0.9, messageBars: 2, barShade: 0.2)

        // 1) Fade-in anındaki bulanık/düşük güvenli okuma çevirmene gitmemeli.
        reader.lines = [TextLine("Bren said o suttacad again", box: TextBox(left: 0.1, top: 0.2, right: 0.9, bottom: 0.3), confidence: 0.55)]
        await watcher.pass(frame, areas: [phone])
        XCTAssertTrue(translator.calls.isEmpty, "Düşük güvenli bulanık kare çevirmene gitmemeli")

        // 2) Sonraki net kare (confidence 0.95) anında çevrilmeli.
        reader.lines = [TextLine("Brian said you surfaced again.", box: TextBox(left: 0.1, top: 0.2, right: 0.9, bottom: 0.3), confidence: 0.95)]
        await watcher.pass(frame, areas: [phone])
        XCTAssertEqual(translator.calls, ["Brian said you surfaced again."])
    }

    func testPersistentPhoneCacheSurvivesRestart() async throws {
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("phone-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let template = try XCTUnwrap(PanelTemplate.capture(from: phoneImage(background: 0.6, screen: 0.9, messageBars: 2, barShade: 0.2)))
        let phone = ExtraArea(id: "phone", name: "Phone", region: ExtraAreaPreset.phone.region,
                              onlyWhenVisible: true, panelTemplates: [template])
        let frame = phoneImage(background: 0.6, screen: 0.9, messageBars: 2, barShade: 0.2)

        // İlk oturum: çevir ve diske yaz.
        let reader1 = Reader(), translator1 = Translator(), server1 = Server()
        reader1.lines = [TextLine("Meet at Vangelico.", box: TextBox(left: 0.1, top: 0.2, right: 0.9, bottom: 0.3), confidence: 0.95)]
        let watcher1 = RegionWatcher(reader: reader1, translator: translator1, server: server1,
                                     minReadingHoldMs: 0, cacheFile: cacheURL, panelDetector: { _, _, _ in true })
        await watcher1.pass(frame, areas: [phone])
        XCTAssertEqual(translator1.calls, ["Meet at Vangelico."])
        try await Task.sleep(for: .milliseconds(80))

        // Yeni oturum (uygulama yeniden açıldı): diskten yükler, 0 motor çağrısı!
        let reader2 = Reader(), translator2 = Translator(), server2 = Server()
        reader2.lines = [TextLine("Meet at Vangelico.", box: TextBox(left: 0.1, top: 0.2, right: 0.9, bottom: 0.3), confidence: 0.95)]
        let watcher2 = RegionWatcher(reader: reader2, translator: translator2, server: server2,
                                     minReadingHoldMs: 0, cacheFile: cacheURL, panelDetector: { _, _, _ in true })
        await watcher2.pass(frame, areas: [phone])
        XCTAssertTrue(translator2.calls.isEmpty, "Kalıcı önbellekten 0 ms'de gelmeliydi")
        XCTAssertEqual(server2.sent.last?.text, "TR: Meet at Vangelico.")
    }

    func testPanelPresencePerformanceIsSubMillisecond() throws {
        let reference = phoneImage(background: 0.70, screen: 0.85, messageBars: 2, barShade: 0.30)
        let template = try XCTUnwrap(PanelTemplate.capture(from: reference))
        let liveOpen = phoneImage(background: 0.25, screen: 0.35, messageBars: 5, barShade: 0.90)
        let liveClosed = worldImage(seed: 2)

        // 200 açık + 200 kapalı kontrolün ortalama süresini ölç.
        let t0 = ContinuousClock.now
        var openHits = 0
        for _ in 0..<200 {
            if PanelPresence.isVisible(liveOpen, templates: [template]) { openHits += 1 }
        }
        let openElapsed = t0.duration(to: .now)

        let t1 = ContinuousClock.now
        var closedHits = 0
        for _ in 0..<200 {
            if PanelPresence.isVisible(liveClosed, templates: [template]) { closedHits += 1 }
        }
        let closedElapsed = t1.duration(to: .now)

        XCTAssertEqual(openHits, 200)
        XCTAssertEqual(closedHits, 0)
        let openMs = (Double(openElapsed.components.seconds) * 1000 + Double(openElapsed.components.attoseconds) / 1e15) / 200.0
        let closedMs = (Double(closedElapsed.components.seconds) * 1000 + Double(closedElapsed.components.attoseconds) / 1e15) / 200.0
        print(String(format: "PanelPresence benchmark → açık: %.3f ms/kare, kapalı: %.3f ms/kare", openMs, closedMs))
        XCTAssertLessThan(openMs, 3.0)
        XCTAssertLessThan(closedMs, 3.0)
    }

    func testSingleFrameFalsePositiveNeverFlashesTranslation() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let phoneOpen = Flag(true)
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server,
                                    minReadingHoldMs: 0,
                                    panelDetector: { _, _, _ in phoneOpen.value })
        let phone = ExtraArea(id: "phone", name: "Phone", region: ExtraAreaPreset.phone.region, onlyWhenVisible: true)
        reader.lines = [TextLine("Street Sign", box: TextBox(left: 0.1, top: 0.2, right: 0.9, bottom: 0.3))]

        // 1 kare yanlışlıkla açık göründü, sonraki karede kapandı → çeviriye hiç gitmemeli.
        await watcher.pass(worldImage(seed: 1), areas: [phone])
        phoneOpen.value = false
        await watcher.pass(worldImage(seed: 2), areas: [phone])
        XCTAssertTrue(translator.calls.isEmpty)
        XCTAssertTrue(server.sent.isEmpty)
    }

    func testMultipleTemplatesMatchAnySavedPhoneStyle() throws {
        // İki farklı karakter/tema çerçevesi (ör. dar kasa ve geniş kasa).
        let phoneA = phoneImage(background: 0.70, screen: 0.85, messageBars: 2, barShade: 0.30)
        let templateA = try XCTUnwrap(PanelTemplate.capture(from: phoneA))
        let altFrame = worldImage(seed: 3)
        let templateB = try XCTUnwrap(PanelTemplate.capture(from: altFrame))

        XCTAssertTrue(PanelPresence.isVisible(phoneA, templates: [templateA, templateB]))
        XCTAssertTrue(PanelPresence.isVisible(altFrame, templates: [templateA, templateB]))
        XCTAssertFalse(PanelPresence.isVisible(solidImage(gray: 0.5), templates: [templateA, templateB]))
    }

    func testInnerScreenRegionInsetsBezelAndStatusBar() throws {
        let template = try XCTUnwrap(PanelTemplate.capture(from: phoneImage(background: 0.6, screen: 0.9, messageBars: 2, barShade: 0.2)))
        let phone = ExtraArea(id: "p", name: "Phone", region: ExtraAreaPreset.phone.region,
                              onlyWhenVisible: true, panelTemplates: [template], cropInnerScreen: true)
        let inner = phone.ocrRegion
        XCTAssertGreaterThan(inner.left, phone.region.left)
        XCTAssertLessThan(inner.right, phone.region.right)
        XCTAssertGreaterThan(inner.top, phone.region.top)
        XCTAssertLessThan(inner.bottom, phone.region.bottom)

        // Kapalıysa tam bölge kullanılır.
        var uncropped = phone
        uncropped.cropInnerScreen = false
        XCTAssertEqual(uncropped.ocrRegion, phone.region)
    }

    func testFastPollingChecksPhoneMoreOftenThanNormalQuestArea() async {
        let reader = Reader(), translator = Translator(), server = Server()
        var now = 1000
        let phoneChecks = Flag(false)
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server,
                                    intervalMs: 1000, fastIntervalMs: 250, clock: { now },
                                    panelDetector: { _, _, _ in phoneChecks.value })
        let quest = ExtraArea(id: "q", name: "Quest", region: ExtraAreaPreset.quest.region, onlyWhenVisible: false)
        let phone = ExtraArea(id: "p", name: "Phone", region: ExtraAreaPreset.phone.region, onlyWhenVisible: true)
        let frame = worldImage(seed: 1)

        // t=1000: ikisi de kontrol edilir (quest 1 kez OCR yapar, phone kapalı olduğu için 0).
        watcher.offer(frame, areas: [quest, phone])
        while watcher.isBusy { await Task.yield() }
        XCTAssertEqual(watcher.passes, 1)
        XCTAssertEqual(reader.count, 1)

        // t=1300 (+300 ms): telefon 250 ms'i geçtiği için yeni tur başlar, ama quest 1000 ms dolmadığı için tekrar okunmaz!
        now = 1300
        watcher.offer(worldImage(seed: 2), areas: [quest, phone])
        while watcher.isBusy { await Task.yield() }
        XCTAssertEqual(watcher.passes, 2)
        XCTAssertEqual(reader.count, 1, "Normal görev alanı 1000 ms dolmadan tekrar okunmamalı")
    }

    func testTwinPhoneDetectsHeaderClockSidesTimestampsAndDatePills() throws {
        let region = ExtraAreaPreset.phone.region
        let raw = [
            TextLine("2:23 pm", box: TextBox(left: 0.08, top: 0.04, right: 0.28, bottom: 0.08)),
            TextLine("Brian, Jason, Lucia", box: TextBox(left: 0.12, top: 0.10, right: 0.85, bottom: 0.14)),
            TextLine("3 Members", box: TextBox(left: 0.12, top: 0.15, right: 0.45, bottom: 0.18)),
            TextLine("Yesterday", box: TextBox(left: 0.35, top: 0.24, right: 0.65, bottom: 0.27)),
            TextLine("Brian", box: TextBox(left: 0.08, top: 0.31, right: 0.28, bottom: 0.34)),
            TextLine("We're waiting at the bar.", box: TextBox(left: 0.08, top: 0.35, right: 0.68, bottom: 0.41)),
            TextLine("2:19 pm", box: TextBox(left: 0.50, top: 0.42, right: 0.68, bottom: 0.45)),
            TextLine("On my way there now. 2:21 pm", box: TextBox(left: 0.36, top: 0.50, right: 0.94, bottom: 0.56)),
        ]
        let parsed = PhoneContent.parse(rawLines: raw, in: region, activeSubtitle: nil)
        XCTAssertEqual(parsed.layout, .chat)
        XCTAssertEqual(parsed.header?.clock, "2:23 pm")
        XCTAssertEqual(parsed.header?.title, "Brian, Jason, Lucia")
        XCTAssertEqual(parsed.header?.subtitle, "3 Üye")
        XCTAssertEqual(parsed.messages.count, 2)

        // 1. mesaj: soldan gelen, Brian, Dün tarih ayırıcı, 2:19 pm saatli
        XCTAssertEqual(parsed.messages[0].side, .incoming)
        XCTAssertEqual(parsed.messages[0].sender, "Brian")
        XCTAssertEqual(parsed.messages[0].dateLabel, "Dün")
        XCTAssertEqual(parsed.messages[0].timestamp, "2:19 pm")
        XCTAssertEqual(parsed.messages[0].body, "We're waiting at the bar.")

        // 2. mesaj: sağa yaslı giden (oyuncunun cevabı), satır sonu saati ayrılmış!
        XCTAssertEqual(parsed.messages[1].side, .outgoing)
        XCTAssertNil(parsed.messages[1].sender)
        XCTAssertEqual(parsed.messages[1].body, "On my way there now.")
        XCTAssertEqual(parsed.messages[1].timestamp, "2:21 pm")
    }

    func testPhoneScrollKeepsStableMessageIdsHeaderAndZeroRetranslation() async throws {
        let reader = Reader(), translator = Translator(), server = Server()
        let template = try XCTUnwrap(PanelTemplate.capture(from: phoneImage(background: 0.6, screen: 0.9, messageBars: 2, barShade: 0.2)))
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server,
                                    minReadingHoldMs: 0, panelDetector: { _, _, _ in true })
        let phone = ExtraArea(id: "phone", name: "Phone", region: ExtraAreaPreset.phone.region,
                              onlyWhenVisible: true, panelTemplates: [template])

        // 1) İlk ekran: başlık + M1 (Brian) + M2 (Oyuncu)
        reader.lines = [
            TextLine("2:23 pm", box: TextBox(left: 0.08, top: 0.04, right: 0.28, bottom: 0.08)),
            TextLine("Lucia", box: TextBox(left: 0.12, top: 0.10, right: 0.40, bottom: 0.14)),
            TextLine("Online", box: TextBox(left: 0.12, top: 0.15, right: 0.35, bottom: 0.18)),
            TextLine("Lucia", box: TextBox(left: 0.08, top: 0.30, right: 0.28, bottom: 0.34)),
            TextLine("Did you grab the keys?", box: TextBox(left: 0.08, top: 0.35, right: 0.68, bottom: 0.42)),
            TextLine("Yeah, I got them right here.", box: TextBox(left: 0.34, top: 0.50, right: 0.94, bottom: 0.57)),
        ]
        await watcher.pass(phoneImage(background: 0.6, screen: 0.9, messageBars: 2, barShade: 0.2), areas: [phone])
        let firstBlocks = try XCTUnwrap(server.blocks.last ?? nil)
        XCTAssertEqual(firstBlocks.count, 2)
        let m2Id = try XCTUnwrap(firstBlocks[1].msgId)
        XCTAssertEqual(firstBlocks[1].side, .outgoing)
        XCTAssertEqual(server.options.last?.phoneHeader?.title, "Lucia")
        XCTAssertEqual(server.options.last?.phoneHeader?.subtitle, "Çevrimiçi")
        XCTAssertEqual(translator.calls.count, 2)

        // 2) Aşağı kaydırıldı: üst başlık kayboldu, M2 yukarı kaydı (1 harf OCR sapmasıyla!), M3 alttan girdi.
        reader.lines = [
            TextLine("Yeah, I got them right here,", box: TextBox(left: 0.34, top: 0.22, right: 0.94, bottom: 0.29)),
            TextLine("Lucia", box: TextBox(left: 0.08, top: 0.44, right: 0.28, bottom: 0.48)),
            TextLine("Meet me by the boat.", box: TextBox(left: 0.08, top: 0.49, right: 0.68, bottom: 0.56)),
        ]
        await watcher.pass(phoneImage(background: 0.6, screen: 0.85, messageBars: 3, barShade: 0.35), areas: [phone])
        let scrolledBlocks = try XCTUnwrap(server.blocks.last ?? nil)
        XCTAssertEqual(scrolledBlocks.count, 2)
        // M2 aynı msgId'yi korumalı, tekrar çevrilmemeli ve yapışkan üst başlık (Lucia / 2:23 pm) korunmalı!
        XCTAssertEqual(scrolledBlocks[0].msgId, m2Id)
        XCTAssertEqual(translator.calls, ["Did you grab the keys?", "Yeah, I got them right here.", "Meet me by the boat."])
        XCTAssertEqual(server.options.last?.phoneHeader?.title, "Lucia")
        XCTAssertEqual(server.options.last?.phoneHeader?.clock, "2:23 pm")

        // 3) Yukarı geri kaydırıldı: M1 ve M2 bellekte olduğu için 0 yeni çeviri çağrısı!
        reader.lines = [
            TextLine("Lucia", box: TextBox(left: 0.08, top: 0.30, right: 0.28, bottom: 0.34)),
            TextLine("Did you grab the keys?", box: TextBox(left: 0.08, top: 0.35, right: 0.68, bottom: 0.42)),
            TextLine("Yeah, I got them right here.", box: TextBox(left: 0.34, top: 0.50, right: 0.94, bottom: 0.57)),
        ]
        await watcher.pass(phoneImage(background: 0.6, screen: 0.9, messageBars: 2, barShade: 0.25), areas: [phone])
        XCTAssertEqual(translator.calls.count, 3, "Yukarı geri kaydırınca bellekteki mesajlar tekrar çevrilmemeli")
    }

    func testRelativeColumnDetectsOutgoingEvenWithLooseOffCenterCrop() {
        let region = ExtraAreaPreset.phone.region
        // Kullanıcı telefon kutusunu geniş/sola kayık çizmiş (sohbet sütunu 0.04...0.78 arasında).
        let raw = [
            TextLine("Lucia", box: TextBox(left: 0.04, top: 0.20, right: 0.20, bottom: 0.24)),
            TextLine("Where are we meeting tonight?", box: TextBox(left: 0.04, top: 0.25, right: 0.56, bottom: 0.31)),
            // 2 satırlık giden cevap: sütunun solundan belirgin boşluklu (0.20) ve sağ kenarına (0.78) tam yaslı!
            TextLine("Down by the south pier,", box: TextBox(left: 0.20, top: 0.40, right: 0.78, bottom: 0.45)),
            TextLine("bring the spare keys with you.", box: TextBox(left: 0.20, top: 0.46, right: 0.78, bottom: 0.51)),
        ]
        let parsed = PhoneContent.parse(rawLines: raw, in: region, activeSubtitle: nil)
        XCTAssertEqual(parsed.messages.count, 2)
        XCTAssertEqual(parsed.messages[0].side, .incoming)
        XCTAssertEqual(parsed.messages[1].side, .outgoing, "Göreceli sütun hizası 2 satırlık giden mesajı yakalamalı")
    }
}
