// SPDX-License-Identifier: AGPL-3.0-only
#if canImport(CoreGraphics)
import CoreGraphics
import XCTest
@testable import CouchSubsCore

private final class LetterlessReader: TextReader, @unchecked Sendable {
    var texts: [String]
    init(_ texts: [String]) { self.texts = texts }
    func read(_ image: CGImage) throws -> String { texts.isEmpty ? "" : texts.removeFirst() }
}
private final class LetterlessSender: SubtitleSending {
    var sent: [String] = []
    func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) { sent.append(text) }
    func clear() {}
}
private final class LetterlessTranslator: TextTranslator {
    var requested: [String] = []
    func translate(_ text: String) async throws -> String {
        requested.append(text)
        return "TR: " + text
    }
}

/// Hiç harfi olmayan okuma (hız göstergesi, sayaç, plaka sayısı) çevirmene gitmez: çevirmen onu aynen geri verir, satır
/// gösterilmez ama istek ücretlidir. Bir günlük GTA oturumunda çevirmene giden isteklerin beşte biri böyleydi.
@MainActor
final class LetterlessLineTests: XCTestCase {
    private var image: CGImage {
        CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    private func run(_ line: String) async -> (LetterlessTranslator, LetterlessSender) {
        var time = 0
        let translator = LetterlessTranslator(), sender = LetterlessSender()
        let pipeline = SubtitlePipeline(reader: LetterlessReader(Array(repeating: line, count: 4)), translator: translator,
                                        server: sender, clock: { time })
        pipeline.packWait = 0; pipeline.cleanWait = 0; pipeline.holdReadings = true
        for _ in 0..<4 {
            await pipeline.process(image, region: CropRegion())
            await pipeline.waitForTranslations()
            time += 100
        }
        return (translator, sender)
    }

    func testNumbersAreNotSentToTheEngine() async {
        for line in ["350", "20 40 60 80 100 120", "1 / 3", "126-82", "3284975"] {
            let (translator, sender) = await run(line)
            XCTAssertEqual(translator.requested, [], line)
            XCTAssertEqual(sender.sent, [], line)
        }
    }

    func testLinesWithLettersAreStillTranslated() async {
        for line in ["On 1 / 3", "Wait 5 minutes.", "Follow me."] {
            let (translator, _) = await run(line)
            XCTAssertEqual(translator.requested, [line], line)
        }
    }
}
#endif
