// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// PlayStation / Xbox sistem menülerini (güç menüsü, kullanıcı seçimi, depolama ekranı) oyun yazılarından ayırır.
/// Sistem arayüzü ekrana geldiğinde telefon algılayıcısını ya da ücretli çeviri motorunu tetiklememesi için kullanılır.
public enum SystemOverlayFilter {
    private static let phrases: [String] = [
        "ps5 sistemini",
        "dinlenme moduna",
        "dinlenme modu",
        "kontrol cihazini",
        "kontrol cihazi",
        "kullanici ekle",
        "oturum acti",
        "konsol depolama",
        "bulut depolama",
        "kaydedilen veriler",
        "kaydedilen verileri",
        "medya galerisi",
        "resmi haberler",
        "oyunlarinizdan",
        "tum oyunlari ve uygulamalari",
        "oyunu kapat",
        "grand theft auto vi",
        "enter rest mode",
        "turn off ps5",
        "restart ps5",
        "switch user",
        "who is using this controller",
        "console storage",
        "media gallery",
    ]

    /// Metin PS5/konsol sistem menüsüne ait belirgin ifadeler içeriyor mu.
    public static func isSystemOverlay(_ text: String) -> Bool {
        let folded = foldTurkish(text)
        guard !folded.isEmpty else { return false }
        return phrases.contains { folded.contains($0) }
    }

    /// Paragraf dizisi PS5/konsol sistem menüsü ya da tamamen konsol arayüzü mü.
    public static func isSystemOverlay(_ paragraphs: [String]) -> Bool {
        let joined = paragraphs.joined(separator: " ")
        return isSystemOverlay(joined)
    }

    private static func foldTurkish(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = ""
        out.reserveCapacity(lowered.count)
        for ch in lowered {
            switch ch {
            case "ç": out.append("c")
            case "ğ": out.append("g")
            case "ı", "İ", "i": out.append("i")
            case "ö": out.append("o")
            case "ş": out.append("s")
            case "ü": out.append("u")
            default: out.append(ch)
            }
        }
        return out
    }
}
