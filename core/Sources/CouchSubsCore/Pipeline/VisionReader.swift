// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import CoreImage
import Foundation
import Vision

public protocol TextReader: Sendable {
    func read(_ image: CGImage) throws -> String
    /// `deep` false ise boş bölgede büyütülmüş okuma denenmez (işlemciyi çok daha az yorar).
    func read(_ image: CGImage, deep: Bool) throws -> String
    /// Satırlar ayrı ayrı ve görüntüdeki yerleriyle.
    func readLines(_ image: CGImage, deep: Bool) throws -> Reading
    /// `fast` true ise Apple Vision `.fast` (~15-30 ms) ile şimşek hızında ön-okuma yapar (telefon hibrit modu).
    func readLines(_ image: CGImage, deep: Bool, fast: Bool) throws -> Reading
}

extension TextReader {
    public func read(_ image: CGImage, deep: Bool) throws -> String { try read(image) }
    public func readLines(_ image: CGImage, deep: Bool) throws -> Reading { Reading(text: try read(image, deep: deep)) }
    public func readLines(_ image: CGImage, deep: Bool, fast: Bool) throws -> Reading { try readLines(image, deep: deep) }
}

/// Apple Vision ile cihaz üstünde yazı tanıma. Satırlar yukarıdan aşağı sıralanır.
public struct VisionReader: TextReader {
    public var language = "en"

    public init(language: String = "en") {
        self.language = language
    }

    public func read(_ image: CGImage) throws -> String {
        try readLines(image, deep: true).lines.map(\.text).joined(separator: " ")
    }

    public func read(_ image: CGImage, deep: Bool) throws -> String {
        try readLines(image, deep: deep).lines.map(\.text).joined(separator: " ")
    }

    public func readLines(_ image: CGImage, deep: Bool) throws -> Reading {
        deep ? try Self.firstLines(of: image, using: { try recognize($0, fast: false) }) : try recognize(image, fast: false)
    }

    public func readLines(_ image: CGImage, deep: Bool, fast: Bool) throws -> Reading {
        if fast { return try recognize(image, fast: true) }
        return try readLines(image, deep: deep)
    }

    /// Satırsız eski biçim (testler için): bulunan yazı tek metin olarak döner.
    public static func firstReading(of image: CGImage, using recognize: @escaping @Sendable (CGImage) throws -> String) throws -> String {
        try firstLines(of: image) { Reading(text: try recognize($0)) }.text
    }

    /// Vision geniş bölgede "Go!" gibi kısa satırları sık sık hiç bulmaz. Bölgede yazı çıkmazsa
    /// ortadaki şerit (altyazılar ortalıdır) ve bölgenin tamamı büyütülerek aynı anda yeniden okunur;
    /// ikisi de yazı bulursa şeridinki seçilir. Aynı anda okumak, boş karede yeni satırı geç fark etmeyi önler.
    public static func firstLines(of image: CGImage, using recognize: @escaping @Sendable (CGImage) throws -> Reading) throws -> Reading {
        let reading = try recognize(image)
        guard reading.lines.isEmpty else { return reading }

        // Şeritte bulunan satırın yeri şeridin değil bölgenin tamamının oranlarıyla verilir.
        let strip = stripRect(of: image, widthFraction: 0.4)
        let stripArea = TextBox(left: strip.minX / Double(image.width), top: 0, right: strip.maxX / Double(image.width), bottom: 1)
        let fallbacks: [@Sendable () throws -> Reading?] = [
            { try image.cropping(to: strip).flatMap { scaled($0, by: 2) }.map { try recognize($0).placed(in: stripArea) } },
            { try scaled(image, by: 2).map(recognize) },
        ]
        let results = Results(count: fallbacks.count)
        DispatchQueue.concurrentPerform(iterations: fallbacks.count) { index in
            results.set(index, Result { try fallbacks[index]() ?? .empty })
        }
        for result in results.all {
            if let reading = try result?.get(), !reading.lines.isEmpty { return reading }
        }
        return .empty
    }

    /// Aynı anda yapılan okumaların sonuçları.
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Result<Reading, Error>?]
        init(count: Int) { values = Array(repeating: nil, count: count) }
        func set(_ index: Int, _ value: Result<Reading, Error>) { lock.withLock { values[index] = value } }
        var all: [Result<Reading, Error>?] { lock.withLock { values } }
    }

    private func recognize(_ image: CGImage, fast: Bool = false) throws -> Reading {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.recognitionLanguages = [language]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? [])
            .compactMap { observation -> TextLine? in
                guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.5 else { return nil }
                // Vision'ın kutusu sol alttan ölçülür; burada üstten ölçülür.
                let box = Self.textBox(observation.boundingBox)
                return TextLine(candidate.string.trimmingCharacters(in: .whitespacesAndNewlines), box: box,
                                confidence: Double(candidate.confidence), words: Self.words(of: candidate, in: box))
            }
            .sorted { ($0.box?.top ?? 0) < ($1.box?.top ?? 0) }
        return Reading(lines: lines)
    }

    private static func textBox(_ rect: CGRect) -> TextBox {
        TextBox(left: rect.minX, top: 1 - rect.maxY, right: rect.maxX, bottom: 1 - rect.minY)
    }

    /// Boşlukla ayrılan her sözcüğün yeri (`VNRecognizedText.boundingBox(for:)`); yazının içindeki kumanda simgesini
    /// bulmaya yarar (`ButtonIcons`, Windows: WindowsOcrReader sözcük kutuları). Vision bazı sürümlerde sözcük yerine
    /// bütün satırın kutusunu verebilir; sözcükler soldan sağa sıralı değilse ya da biri satırın neredeyse tamamını
    /// kaplıyorsa sözcük yerleri kullanılmaz (nil: yerler harf sayısına göre kestirilir).
    static func words(of candidate: VNRecognizedText, in line: TextBox) -> [TextWord]? {
        let text = candidate.string
        var words: [TextWord] = []
        for word in text.split(whereSeparator: \.isWhitespace) {
            guard let observation = try? candidate.boundingBox(for: word.startIndex..<word.endIndex) else { return nil }
            words.append(TextWord(String(word), box: textBox(observation.boundingBox)))
        }
        guard !words.isEmpty else { return nil }
        let lineWidth = line.right - line.left
        for (index, word) in words.enumerated() {
            guard word.box.right > word.box.left else { return nil }
            if words.count > 1, word.box.right - word.box.left >= lineWidth * 0.9 { return nil }
            if index > 0, word.box.left < words[index - 1].box.left { return nil }
        }
        return words
    }

    private static func stripRect(of image: CGImage, widthFraction: Double) -> CGRect {
        let width = Double(image.width) * widthFraction
        return CGRect(x: (Double(image.width) - width) / 2, y: 0, width: width, height: Double(image.height)).integral
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Küçük telefon/bildirim yazılarını OCR öncesi 2× büyütüp hafif kontrast ve keskinlik uygular.
    /// Vision kutuları 0–1 oranında döndüğü için koordinatlar değişmez; "Bren/suttacad" gibi küçük font hatalarını giderir.
    public static func enhanceSmallText(_ image: CGImage) -> CGImage {
        let base = image.width < 640 ? (scaled(image, by: 2) ?? image) : image
        let input = CIImage(cgImage: base)
        let contrasted = input.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 1.14,
            kCIInputSaturationKey: 1.0
        ])
        let sharpened = contrasted.applyingFilter("CISharpenLuminance", parameters: [
            kCIInputSharpnessKey: 0.42
        ])
        return ciContext.createCGImage(sharpened, from: sharpened.extent) ?? base
    }

    private static func scaled(_ image: CGImage, by factor: Int) -> CGImage? {
        let width = image.width * factor, height = image.height * factor
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
