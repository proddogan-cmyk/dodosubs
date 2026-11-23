// SPDX-License-Identifier: AGPL-3.0-only

#if canImport(CoreGraphics)
import CoreGraphics
@testable import CouchSubsCore
import XCTest

final class PhoneVisionTests: XCTestCase {
    private func makeImage(width: Int = 400, height: Int = 720, r: CGFloat = 0.1, g: CGFloat = 0.2, b: CGFloat = 0.3) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 1 - r, green: 1 - g, blue: 1 - b, alpha: 1)
        ctx.fill(CGRect(x: 40, y: 80, width: width - 80, height: height / 3))
        return ctx.makeImage()!
    }

    func testEncodeJPEGResizesAndOutputsValidJPEG() {
        let large = makeImage(width: 900, height: 1600)
        let data = PhoneVisionTranslator.encodeJPEG(large)
        XCTAssertNotNil(data)
        XCTAssertTrue(data!.count > 100 && data!.count < 200_000)
        // JPEG magic bytes FF D8
        XCTAssertEqual(data![0], 0xFF)
        XCTAssertEqual(data![1], 0xD8)
    }

    func testMakeRequestBuildsMultimodalPayloadsForClaudeGeminiOpenAI() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])

        let claudeReq = PhoneVisionTranslator.makeRequest(provider: .claude, key: "sk-ant-test",
                                                          model: AIProvider.claude.defaultModel,
                                                          jpegData: jpeg, game: "Grand Theft Auto VI")
        XCTAssertEqual(claudeReq.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        let claudeBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(claudeReq.httpBody)) as? [String: Any])
        let claudeMessages = try XCTUnwrap(claudeBody["messages"] as? [[String: Any]])
        let claudeContent = try XCTUnwrap(claudeMessages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(claudeContent[0]["type"] as? String, "image")
        XCTAssertEqual((claudeContent[0]["source"] as? [String: Any])?["media_type"] as? String, "image/jpeg")

        let geminiReq = PhoneVisionTranslator.makeRequest(provider: .gemini, key: "AIza-test",
                                                          model: AIProvider.gemini.defaultModel,
                                                          jpegData: jpeg, game: "Grand Theft Auto VI")
        XCTAssertEqual(geminiReq.value(forHTTPHeaderField: "x-goog-api-key"), "AIza-test")
        let geminiBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(geminiReq.httpBody)) as? [String: Any])
        let geminiConfig = try XCTUnwrap(geminiBody["generationConfig"] as? [String: Any])
        XCTAssertEqual(geminiConfig["responseMimeType"] as? String, "application/json")

        let openAIReq = PhoneVisionTranslator.makeRequest(provider: .openAI, key: "sk-openai",
                                                          model: AIProvider.openAI.defaultModel,
                                                          jpegData: jpeg)
        XCTAssertEqual(openAIReq.value(forHTTPHeaderField: "Authorization"), "Bearer sk-openai")
        let openAIBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(openAIReq.httpBody)) as? [String: Any])
        XCTAssertEqual((openAIBody["response_format"] as? [String: Any])?["type"] as? String, "json_object")
    }

    func testParseResultHandlesChatInboxQuietAndFencedJSON() throws {
        let chatJSON = """
        ```json
        {
          "screen": "chat",
          "title": "Jason",
          "subtitle": "Çevrimiçi",
          "clock": "2:21 pm",
          "messages": [
            {"side":"incoming","sender":"Jason","time":"2:19 pm","date":"Bugün","tr":"Anladım. Mia nasıl?"},
            {"side":"outgoing","sender":"Lucia","time":"2:20 pm","date":null,"tr":"Hiç sorma bile..."}
          ]
        }
        ```
        """
        let parsed = try PhoneVisionTranslator.parseResult(from: chatJSON)
        XCTAssertEqual(parsed.screen, .chat)
        XCTAssertEqual(parsed.title, "Jason")
        XCTAssertEqual(parsed.clock, "2:21 pm")
        XCTAssertEqual(parsed.messages.count, 2)
        XCTAssertEqual(parsed.messages[0].side, .incoming)
        XCTAssertEqual(parsed.messages[0].sender, "Jason")
        XCTAssertEqual(parsed.messages[0].date, "Bugün")
        XCTAssertEqual(parsed.messages[1].side, .outgoing)
        XCTAssertNil(parsed.messages[1].sender, "Giden balonda gönderen adı gösterilmez")

        let quiet = try PhoneVisionTranslator.parseResult(from: #"{"screen":"quiet","title":null,"messages":[]}"#)
        XCTAssertEqual(quiet.screen, .quiet)
        XCTAssertTrue(quiet.messages.isEmpty)
    }

    @MainActor
    func testRegionWatcherUsesDirectVisionWithPerceptualCacheAndFallback() async {
        final class FakeVision: PhoneVisionReading, @unchecked Sendable {
            private let lock = NSLock()
            var calls = 0
            var failNext = false
            var nextResult = PhoneVisionResult(
                screen: .chat,
                title: "Jason",
                subtitle: "Çevrimiçi",
                clock: "2:21 pm",
                messages: [
                    .init(side: .incoming, sender: "Jason", time: "2:19 pm", text: "Anladım. Mia nasıl?"),
                    .init(side: .outgoing, time: "2:20 pm", text: "Yoldayım. Tacolarımı paket yaptır."),
                ]
            )
            func analyzePhone(_ image: CGImage, activeSubtitle: String?) async throws -> PhoneVisionResult {
                try lock.withLock {
                    calls += 1
                    if failNext {
                        failNext = false
                        throw AIFailure.busy
                    }
                    return nextResult
                }
            }
        }
        final class UnusedReader: TextReader, @unchecked Sendable {
            private let lock = NSLock()
            var reads = 0
            func read(_ image: CGImage) throws -> String {
                lock.withLock { reads += 1 }
                return "Fallback text"
            }
        }
        final class DummyTranslator: TextTranslator {
            func translate(_ text: String) async throws -> String { "Yedek çeviri" }
        }
        final class CaptureServer: RegionSending {
            var sent: [(text: String, blocks: [ScreenTranslation.Item]?, header: PhoneContent.Header?)] = []
            func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) {}
            func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                            blocks: [ScreenTranslation.Item]?, presentation: RegionPresentation, anchor: TextBox?,
                            options: BubbleOptions) {
                if !options.loading {
                    sent.append((text, blocks, options.phoneHeader))
                }
            }
            func clearRegions() {}
        }

        var clock = 10_000
        let vision = FakeVision()
        let reader = UnusedReader()
        let server = CaptureServer()
        let watcher = RegionWatcher(reader: reader, translator: DummyTranslator(), server: server,
                                    minReadingHoldMs: 0, clock: { clock }, panelDetector: { _, _, _ in true })
        watcher.phoneVision = vision

        let area = ExtraArea(id: "phone", name: "Telefon",
                             region: CropRegion(top: 0.40, bottom: 0.92, left: 0.72, right: 0.96),
                             onlyWhenVisible: true, presentation: .sideBubble)
        let frame1 = makeImage(r: 0.1, g: 0.2, b: 0.3)
        let frame2 = makeImage(r: 0.85, g: 0.75, b: 0.15)

        // 1) İlk açılış: doğrudan Vision çağrılır, OCR hiç çalışmaz.
        await watcher.pass(frame1, areas: [area])
        XCTAssertEqual(vision.calls, 1)
        XCTAssertEqual(reader.reads, 0)
        XCTAssertEqual(server.sent.count, 1)
        XCTAssertEqual(server.sent[0].blocks?.count, 2)
        XCTAssertEqual(server.sent[0].blocks?[0].side, .incoming)
        XCTAssertEqual(server.sent[0].blocks?[1].side, .outgoing)
        XCTAssertEqual(server.sent[0].header?.title, "Jason")

        // 2) Sabit ekran: tekrar Vision çağrılmaz, TV titremez.
        clock += 1000
        await watcher.pass(frame1, areas: [area])
        XCTAssertEqual(vision.calls, 1)
        XCTAssertEqual(server.sent.count, 1)

        // 3) Farklı ekrana kaydırma → yeni Vision çağrısı; sonra frame1'e geri dönünce 0 ms algısal önbellek!
        clock += 1000
        vision.nextResult = PhoneVisionResult(screen: .inbox, title: "Sohbetler", messages: [
            .init(side: .incoming, sender: "Vicki, Jason, Lucia", text: "Neredeyse geldik!"),
        ])
        await watcher.pass(frame2, areas: [area])
        XCTAssertEqual(vision.calls, 2)
        XCTAssertEqual(server.sent.count, 2)

        clock += 1000
        await watcher.pass(frame1, areas: [area])
        XCTAssertEqual(vision.calls, 2, "Önceki ekrana geri kaydırınca algısal önbellekten 0 ms'de dönmeli")
        XCTAssertEqual(server.sent.count, 3)
        XCTAssertEqual(server.sent[2].blocks?.count, 2)
    }

    @MainActor
    func testLogRegressionsProtected() {
        var rows = StickyRows()
        let mono1 = "Nah, see look, I'm tryin' to do you a favor, so maybe, maybe,"
        let mono2 = "You comfortable where you at. I see that."
        _ = rows.filter(Reading(text: mono1 + "\n" + mono2), at: 0)
        _ = rows.filter(Reading(text: mono1 + "\n" + mono2 + "\nBitch."), at: 5000)
        let kept = rows.filter(Reading(text: mono1 + "\n" + mono2 + "\nBitch."), at: 15_000)
        XCTAssertTrue(kept.text.contains(mono1))
        XCTAssertTrue(kept.text.contains(mono2))

        XCTAssertTrue(SystemOverlayFilter.isSystemOverlay("Bulut depolama alanındaki kaydedilen veriler kontrol ediliyor..."))
        XCTAssertTrue(SystemOverlayFilter.isSystemOverlay("Kaydedilen Verileri Seç"))
        XCTAssertTrue(TurkishText.isSure("Bulut depolama alanındaki kaydedilen veriler kontrol ediliyor..."))
        XCTAssertTrue(SubtitlePipeline.isRepeatedCharNoise("duuu"))
        XCTAssertFalse(SubtitlePipeline.isRepeatedCharNoise("Yeah!"))
    }
}
#endif
