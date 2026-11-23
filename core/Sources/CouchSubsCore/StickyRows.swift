// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Konuşma değişirken ekranda sabit duran satırı (görev/HUD yazısı) okumadan çıkarır. GTA 6'da görev yazısı ("Get in
/// the sea plane", "Stash the acid in Brian's lockup") konuşma altyazısının hemen altında, dakikalarca durur; yazı
/// tanıma ikisini tek blok okuyordu ("Thought I was flying solo. Come on.\nGet in the sea plane"). Konuşma kalkıp görev
/// tek başına kalınca kararlayıcı bunu gönderilenin bir satırı eksik okuması sayıyor, TV'de eski konuşmanın çevirisi
/// görev yazısı durdukça kalıyordu; kısa yeni konuşma da uzun görev satırı yüzünden aynı altyazı sayılıp hiç
/// çevrilmiyordu. Bir satır en az `stickyMs` ekranda kaldıysa ve yanında ondan en az `youngerByMs` sonra gelmiş başka
/// bir satır varsa sabit (HUD) sayılır; sabit satır, ekrandan kalkana dek (tek başına kalsa da) okumadan çıkarılır.
/// Satırları birlikte beliren konuşma kutusu (sayfa sayfa okunan diyaloglar) etkilenmez
/// (Windows: StickyRows.cs, Android: StickyRows.kt).
public struct StickyRows {
    /// Satır bu kadar ekranda kalmadan sabit sayılmaz.
    public static let stickyMs = 6000
    /// Nokta (`.`) ile biten tam cümlelerin sabit sayılması için daha uzun eşik (gerçek diyalog yutulmasın).
    public static let sentenceStickyMs = 10_000
    /// Yanındaki satırın en az bu kadar sonra gelmiş olması gerekir (birlikte beliren satırlar konuşmadır).
    public static let youngerByMs = 3000
    /// Bu kadar okunmayan satır ekrandan kalkmış sayılır (birkaç karelik okuma kaçağı satırı unutturmaz).
    public static let forgetAfterMs = 1500

    private struct Row {
        var text: String
        var raw: String
        var since: Int
        var lastSeen: Int
        var sticky = false
    }

    /// Konuşma/sohbet satırı olduğu bariz olan satırlar (soru/ünlem/üç nokta, konuşan etiketi, küçük harfle başlayan
    /// devam ya da günlük sohbet) görev/HUD yazısı sayılmaz.
    static func looksLikeDialogue(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if SpeakerPrefix.split(trimmed) != nil { return true }
        if let first = trimmed.first, first.isLowercase || first == "\"" || first == "“" || first == "-" || first == "—" {
            return true
        }
        if trimmed.hasSuffix("?") || trimmed.hasSuffix("!") || trimmed.hasSuffix("...") || trimmed.hasSuffix("…") {
            return true
        }
        return false
    }

    private var rows: [Row] = []
    /// Son `filter` çağrısında ilk kez sabit sayılan satırlar (günlük için).
    public private(set) var newlySticky: [String] = []

    public init() {}

    /// Okumanın sabit (HUD) satırları çıkarılmış hali. `time`: milisaniye saati.
    public mutating func filter(_ reading: Reading, at time: Int) -> Reading {
        newlySticky = []
        var matched: [Int?] = []
        var used = Set<Int>()
        for line in reading.lines {
            let text = TextMatch.normalize(line.text)
            guard text.count >= 3 else { matched.append(nil); continue }
            if let index = rows.indices.first(where: { !used.contains($0) && TextMatch.isSimilar(text, rows[$0].text) }) {
                rows[index].lastSeen = time
                rows[index].raw = line.text
                used.insert(index)
                matched.append(index)
            } else {
                rows.append(Row(text: text, raw: line.text, since: time, lastSeen: time))
                used.insert(rows.count - 1)
                matched.append(rows.count - 1)
            }
        }
        let present = matched.compactMap { $0 }
        for index in present where !rows[index].sticky {
            let raw = rows[index].raw
            if Self.looksLikeDialogue(raw) { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let requiredMs = trimmed.hasSuffix(".") ? Self.sentenceStickyMs : Self.stickyMs
            guard time - rows[index].since >= requiredMs else { continue }
            let since = rows[index].since
            if present.contains(where: { rows[$0].since - since >= Self.youngerByMs }) {
                rows[index].sticky = true
                newlySticky.append(reading.lines[matched.firstIndex(of: index)!].text)
            }
        }
        let kept = zip(reading.lines, matched).filter { _, index in index.map { !rows[$0].sticky } ?? true }.map(\.0)
        // Kalkan satırlar unutulur (dizinler yukarıda kullanıldı; silme en sonda).
        rows.removeAll { time - $0.lastSeen > Self.forgetAfterMs }
        return kept.count == reading.lines.count ? reading : Reading(lines: kept)
    }

    public mutating func reset() {
        rows.removeAll()
        newlySticky = []
    }
}
