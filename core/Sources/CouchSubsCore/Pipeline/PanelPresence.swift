// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Vision

/// Bir oyun içi panelin (özellikle cep telefonunun) dış çerçevesinin kenar gradyanı imzası.
///
/// Sadece bölgenin dış çerçeve halkasındaki (bezel, üst durum çubuğu, alt kenar) kenar şiddetlerini saklar; ekranın
/// ortasındaki değişken içerik (mesajlar, uygulamalar, duvar kağıdı) maskelenerek yok sayılır. Böylece telefonun içinde
/// hangi uygulama açılırsa açılsın eşleşme bozulmaz; telefon kapandığında ise dış çerçeve kaybolduğu için eşleşme hızla düşer.
public struct PanelTemplate: Codable, Equatable, Sendable {
    public static let defaultWidth = 48
    public static let defaultHeight = 64
    public static let defaultBorderX = 11
    public static let defaultBorderY = 12
    /// Düz/boş kareleri (ör. siyah yükleme ekranı) geçersiz saymak için en düşük kenar standart sapması.
    public static let minEdgeEnergy = 10.0

    public var width: Int
    public var height: Int
    public var borderX: Int
    public var borderY: Int
    /// Çerçeve halkasındaki her pikselin Sobel kenar şiddeti (0–255).
    public var edges: Data

    public init(width: Int, height: Int, borderX: Int, borderY: Int, edges: Data) {
        self.width = width
        self.height = height
        self.borderX = borderX
        self.borderY = borderY
        self.edges = edges
    }

    /// Kırpılmış görüntüden çerçeve şablonu çıkarır. Görüntüde anlamlı kenar yoksa (boş/tek renk) nil döner.
    public static func capture(from crop: CGImage,
                               width: Int = defaultWidth,
                               height: Int = defaultHeight,
                               borderX: Int = defaultBorderX,
                               borderY: Int = defaultBorderY) -> PanelTemplate? {
        let edges = PanelPresence.borderEdges(of: crop, width: width, height: height, borderX: borderX, borderY: borderY)
        guard !edges.isEmpty, PanelPresence.standardDeviation(of: edges) >= minEdgeEnergy else { return nil }
        return PanelTemplate(width: width, height: height, borderX: borderX, borderY: borderY, edges: Data(edges))
    }

    /// Canlı kırpılmış görüntüyle sıfır ortalamalı normalize çapraz korelasyon (NCC) benzerliği (-1...1).
    /// Karakter elinde tuttuğu telefonu hafifçe salladığında (nefes alma / yürüme / sürüş) eşleşmenin düşmemesi için
    /// ±2 hücrelik küçük kaydırmalarda en iyi eşleşmeyi alır. Kenarsız/düz karelerde 0 döner.
    public func similarity(to crop: CGImage) -> Double {
        let grid = PanelPresence.sobelGrid(of: crop, width: width, height: height)
        guard !grid.isEmpty, !edges.isEmpty else { return 0 }
        var best = -1.0
        for dy in -2...2 {
            for dx in -2...2 {
                let live = PanelPresence.extractBorder(from: grid, width: width, height: height,
                                                       borderX: borderX, borderY: borderY, dx: dx, dy: dy)
                guard live.count == edges.count else { continue }
                let score = PanelPresence.ncc(edges, live, minStdDev: Self.minEdgeEnergy)
                if score > best { best = score }
            }
        }
        return best > -1.0 ? best : 0
    }

    /// Görüntü bu çerçeve şablonuyla eşleşiyor mu.
    public func matches(_ crop: CGImage, threshold: Double = PanelPresence.defaultThreshold) -> Bool {
        similarity(to: crop) >= threshold
    }
}

/// Ek alanda telefon veya açılır-kapanır bir panelin o an görünür olup olmadığını algılar.
///
/// - Kullanıcı "Telefonu tanıt" ile bir veya daha fazla şablon kaydettiyse çok hızlı (< 1 ms) dış çerçeve kenar
///   korelasyonu kullanır; şablonlardan herhangi biri eşleşirse panel açık sayılır.
/// - Şablon yoksa Apple Vision dikdörtgen tespitiyle bölgede dikey bir telefon çerçevesi arar.
public enum PanelPresence {
    /// Tanıtılmış çerçeve eşleşmesi için varsayılan NCC eşiği.
    public static let defaultThreshold = 0.42
    public static let minThreshold = 0.25
    public static let maxThreshold = 0.70

    /// Eşik değerini güvenli aralığa sıkıştırır.
    public static func clampedThreshold(_ value: Double) -> Double {
        min(maxThreshold, max(minThreshold, value))
    }

    /// Kayıtlı şablonlar arasındaki en yüksek benzerlik skoru (0...1). Şablon yoksa 0 döner.
    public static func bestSimilarity(of crop: CGImage, templates: [PanelTemplate]) -> Double {
        guard !templates.isEmpty else { return 0 }
        var best = 0.0
        for template in templates {
            let score = template.similarity(to: crop)
            if score > best { best = score }
        }
        return max(0, min(1, best))
    }

    /// Kırpılmış bölgede panel/telefon şu an açık mı.
    public static func isVisible(_ crop: CGImage, templates: [PanelTemplate],
                                 threshold: Double = defaultThreshold) -> Bool {
        if !templates.isEmpty {
            return bestSimilarity(of: crop, templates: templates) >= clampedThreshold(threshold)
        }
        return detectRectangle(in: crop)
    }

    /// Tek şablonlu geriye dönük yardımcı.
    public static func isVisible(_ crop: CGImage, template: PanelTemplate?) -> Bool {
        isVisible(crop, templates: template.map { [$0] } ?? [])
    }

    /// Telefonun dış kasasını (bezel) ve üst durum çubuğunu (saat/pil/sinyal) dışarıda bırakarak sadece iç ekran
    /// bölgesini döner; böylece OCR kenardan sızan oyun dünyası yazılarını ve durum çubuğunu okumaz.
    public static func innerScreenRegion(of region: CropRegion) -> CropRegion {
        let width = region.right - region.left
        let height = region.bottom - region.top
        let insetX = width * 0.07
        let insetTop = height * 0.11
        let insetBottom = height * 0.07
        let left = region.left + insetX
        let right = region.right - insetX
        let top = region.top + insetTop
        let bottom = region.bottom - insetBottom
        guard right - left >= CropRegion.minimumSize, bottom - top >= CropRegion.minimumSize else {
            return region
        }
        return CropRegion(top: top, bottom: bottom, left: left, right: right)
    }

    /// Şablon olmadan otomatik algılama: bölgede dikey bir telefon/panel dikdörtgeni var mı.
    public static func detectRectangle(in crop: CGImage) -> Bool {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.30
        request.maximumAspectRatio = 0.90
        request.minimumSize = 0.35
        request.minimumConfidence = 0.65
        request.quadratureTolerance = 18
        request.maximumObservations = 1
        do {
            try VNImageRequestHandler(cgImage: crop).perform([request])
        } catch {
            return false
        }
        return !(request.results?.isEmpty ?? true)
    }

    /// Görüntüyü küçültüp gri tona çevirir ve 48×64 Sobel kenar şiddeti ızgarasını çıkarır.
    static func sobelGrid(of image: CGImage, width: Int, height: Int) -> [UInt8] {
        guard width >= 4, height >= 4 else { return [] }
        var gray = [UInt8](repeating: 0, count: width * height)
        gray.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        var sobel = [UInt8](repeating: 0, count: width * height)
        for y in 1..<(height - 1) {
            let rowAbove = (y - 1) * width
            let row = y * width
            let rowBelow = (y + 1) * width
            for x in 1..<(width - 1) {
                let tl = Int(gray[rowAbove + x - 1])
                let tc = Int(gray[rowAbove + x])
                let tr = Int(gray[rowAbove + x + 1])
                let ml = Int(gray[row + x - 1])
                let mr = Int(gray[row + x + 1])
                let bl = Int(gray[rowBelow + x - 1])
                let bc = Int(gray[rowBelow + x])
                let br = Int(gray[rowBelow + x + 1])

                let gx = -tl + tr - 2 * ml + 2 * mr - bl + br
                let gy = -tl - 2 * tc - tr + bl + 2 * bc + br
                let mag = Int((Double(gx * gx + gy * gy).squareRoot()) / 4.0)
                sobel[row + x] = UInt8(min(255, mag))
            }
        }
        return sobel
    }

    /// Sobel ızgarasından sadece dış çerçeve halkasını `(dx, dy)` kaydırmayla çeker.
    static func extractBorder(from sobel: [UInt8], width: Int, height: Int, borderX: Int, borderY: Int,
                              dx: Int = 0, dy: Int = 0) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(width * height / 2)
        for y in 1..<(height - 1) {
            let inBorderY = y < borderY || y >= height - borderY
            let sy = min(height - 1, max(0, y + dy))
            let row = sy * width
            for x in 1..<(width - 1) {
                guard inBorderY || x < borderX || x >= width - borderX else { continue }
                let sx = min(width - 1, max(0, x + dx))
                result.append(sobel[row + sx])
            }
        }
        return result
    }

    /// Görüntüyü küçültüp gri tona çevirir, ardından sadece dış çerçeve halkasındaki Sobel kenar şiddetlerini çıkarır.
    static func borderEdges(of image: CGImage, width: Int, height: Int, borderX: Int, borderY: Int) -> [UInt8] {
        let sobel = sobelGrid(of: image, width: width, height: height)
        guard !sobel.isEmpty else { return [] }
        return extractBorder(from: sobel, width: width, height: height, borderX: borderX, borderY: borderY)
    }

    static func standardDeviation(of values: [UInt8]) -> Double {
        guard !values.isEmpty else { return 0 }
        let count = Double(values.count)
        let mean = values.reduce(0.0) { $0 + Double($1) } / count
        let variance = values.reduce(0.0) { acc, v in
            let d = Double(v) - mean
            return acc + d * d
        } / count
        return variance.squareRoot()
    }

    /// Sıfır ortalamalı normalize çapraz korelasyon (NCC).
    static func ncc(_ a: Data, _ b: [UInt8], minStdDev: Double) -> Double {
        let count = a.count
        guard count == b.count, count > 0 else { return 0 }
        let n = Double(count)
        var sumA = 0.0, sumB = 0.0
        for i in 0..<count {
            sumA += Double(a[i])
            sumB += Double(b[i])
        }
        let meanA = sumA / n
        let meanB = sumB / n

        var num = 0.0, varA = 0.0, varB = 0.0
        for i in 0..<count {
            let da = Double(a[i]) - meanA
            let db = Double(b[i]) - meanB
            num += da * db
            varA += da * da
            varB += db * db
        }
        guard (varA / n).squareRoot() >= minStdDev, (varB / n).squareRoot() >= minStdDev else { return 0 }
        let denom = (varA * varB).squareRoot()
        guard denom > 0 else { return 0 }
        return max(-1.0, min(1.0, num / denom))
    }
}
