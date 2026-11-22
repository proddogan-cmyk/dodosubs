// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Oyun içi telefon ekranından okunan metni temizler, ana altyazı sızıntısını ayıklar ve her mesajı
/// gönderen/gövde olarak ayrı bloklara böler.
///
/// GTA 6 gibi oyunlarda telefonun alt kenarına ana diyalog altyazısı sızabiliyor; ayrıca saat ("2:21 pm"),
/// şifreleme etiketi ("Messages encrypted") ve üye sayısı ("3 Members") gibi sabit telefon arayüzü yazıları
/// mesajla tek paragrafta yapıştığında oyun paketi (`paket:gta-6`) ıskalanıp yavaş internet çevirisine düşüyordu.
public enum PhoneContent {
    /// Telefon ekranında açık olan uygulamanın görsel yerleşim kipi.
    public enum Layout: String, Codable, Equatable, Sendable {
        /// Mesajlaşma / WhatUp: her mesaj kendi gönderen renkli balonuyla.
        case chat
        /// E-posta / haber / sosyal medya / uzun not: tek, düzenli buzlu cam okuma kartı.
        case card
        /// Ana ekran ikonları / kamera / harita: çevrilecek cümle yok, TV sessiz kalır.
        case quiet
    }

    public struct Parsed: Equatable, Sendable {
        public var layout: Layout
        public var messages: [Message]

        public init(layout: Layout, messages: [Message]) {
            self.layout = layout
            self.messages = messages
        }
    }

    public struct Message: Equatable, Sendable {
        public var sender: String?
        public var senderColor: String?
        public var body: String
        public var box: TextBox
        public var lineHeight: Double

        public init(sender: String?, senderColor: String? = nil, body: String, box: TextBox, lineHeight: Double) {
            self.sender = sender
            self.senderColor = senderColor
            self.body = body
            self.box = box
            self.lineHeight = lineHeight
        }
    }

    /// Ana ekran / kamera uygulama simgesi etiketleri (tek başına ekranda sadece bunlar varsa TV sessiz kalır).
    private static let homeIconWords: Set<String> = [
        "camera", "snapmatic", "map", "maps", "settings", "clock", "contacts", "phone",
        "whatup", "internet", "browser", "email", "mail", "gallery", "photos", "music",
        "calendar", "notes", "weather", "social", "bleeter", "jobs", "quick join", "apps"
    ]

    /// Her karakter için sabit, yüksek kontrastlı imza rengi (GTA 6 ana karakterleri için özel palet).
    public static func colorHex(forSender name: String) -> String {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.contains("lucia") || lower == "lu" { return "#fb7185" }
        if lower.contains("jason") || lower == "jay" { return "#38bdf8" }
        if lower.contains("brian") { return "#fbbf24" }
        let palette = ["#34d399", "#c084fc", "#f472b6", "#60a5fa", "#fb923c", "#a3e635"]
        let hash = lower.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }

    /// Telefon arayüzü gürültüsü: saat, şifreleme etiketi, bildirim/üye sayacı.
    private static let chromePhrases: Set<String> = [
        "messages encrypted", "end to end encrypted", "end-to-end encrypted", "encrypted",
        "new message", "new messages", "type a message", "send message", "send a message",
        "online", "offline", "typing", "delivered", "read", "sent",
        "yesterday", "today", "just now", "now", "reminders", "notifications",
        "back", "reply", "options", "menu", "search", "chats", "messages", "contacts",
        "5g", "4g", "lte", "wifi", "wi fi", "wi-fi"
    ]

    /// Tek başına konuşmacı/gönderen adı olamayacak sık kullanılan İngilizce başlangıç sözcükleri.
    private static let nonSenderWords: Set<String> = [
        "the", "this", "that", "these", "those", "you", "your", "we", "our", "they", "their",
        "what", "who", "when", "where", "why", "how", "hey", "hi", "hello", "yeah", "yes", "no",
        "okay", "ok", "sure", "wait", "just", "please", "thanks", "sorry", "well", "good", "bad",
        "call", "meet", "come", "going", "ready", "done", "check", "look", "need", "want", "got",
        "new", "all", "more", "view", "open", "close", "delete", "send", "cancel"
    ]

    /// Satır saf telefon arayüzü gürültüsü mü (saat, "3 Members", "Messages encrypted", "4 Notifications" vb.).
    public static func isChrome(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        // Baştaki simge/OCR artıklarını ("& Messages encrypted", "• 3 Members") soy.
        let cleaned = trimmed.drop(while: { !$0.isLetter && !$0.isNumber })
        let lower = cleaned.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        guard !lower.isEmpty else { return true }

        if chromePhrases.contains(lower) { return true }

        // Saat biçimleri: "1:46 pm", "2:23 PM", "14:05", "9:05 a.m."
        if lower.range(of: #"^\d{1,2}[:.]\d{2}(\s*[ap]\.?m\.?)?$"#, options: .regularExpression) != nil {
            return true
        }
        // Sayı + telefon sayaç sözcüğü: "3 members", "4 notifications", "2 unread", "1 new message"
        if lower.range(of: #"^\d+\s+(members?|notifications?|unread|new\s+messages?|messages?|reminders?|contacts?|missed\s+calls?)$"#,
                       options: .regularExpression) != nil {
            return true
        }
        // Sadece yüzdelik pil / sinyal ("84%", "100%")
        if lower.range(of: #"^\d{1,3}%$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// Telefon kutusunun içinden hem sabit arayüz gürültüsünü hem de ekranda o an gösterilen ana diyalog altyazısını
    /// ayıklar. Böylece karakterler konuşurken ana altyazı telefon balonuna sızmaz.
    public static func filterLines(_ lines: [TextLine], activeSubtitle: String?) -> [TextLine] {
        var result = lines.filter { !isChrome($0.text) }
        guard let activeSubtitle else { return result }
        let normSub = TextMatch.normalize(activeSubtitle)
        guard normSub.count >= 5 else { return result }

        // 1) Tekil satırlardan ana altyazının parçası veya benzeri olanları çıkar.
        result.removeAll { line in
            matchesSubtitle(line.text, normalizedSubtitle: normSub)
        }

        // 2) Alttaki iki satır birleştiğinde ana altyazıyı oluşturuyorsa ikisini birden çıkar.
        if result.count >= 2 {
            let tail = result.suffix(2).map(\.text).joined(separator: " ")
            if matchesSubtitle(tail, normalizedSubtitle: normSub) {
                result.removeLast(2)
            }
        }
        return result
    }

    private static func matchesSubtitle(_ candidate: String, normalizedSubtitle: String) -> Bool {
        let norm = TextMatch.normalize(candidate)
        guard norm.count >= 4 else { return false }
        if normalizedSubtitle == norm { return true }
        if norm.count >= 8, normalizedSubtitle.contains(norm) || norm.contains(normalizedSubtitle) {
            return true
        }
        return TextMatch.isSimilar(norm, normalizedSubtitle, threshold: 0.68)
    }

    /// Tek başına duran kısa bir satır gönderen/kişi adı mı ("Brian", "Lucia", "Jason", "Aunt Denise").
    public static func isLikelySenderHeader(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 22 else { return false }
        // Cümle sonu noktalama, soru/ünlem veya virgül listesi ("Brian, Jason, Lucia") içeren satırlar tek gönderen değildir.
        if trimmed.contains(where: { ".?!,;()[]".contains($0) }) { return false }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard words.count >= 1, words.count <= 2 else { return false }
        guard let first = words.first, let firstChar = first.first, firstChar.isUppercase else { return false }
        if nonSenderWords.contains(first.lowercased()) { return false }
        return words.allSatisfy { word in
            word.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" }
        }
    }

    /// `"Brian: We're at the bar."` gibi tek satırda iki noktalı gönderen ön ekini ayırır.
    public static func splitInlineSender(_ text: String) -> (sender: String?, body: String) {
        guard let colon = text.firstIndex(of: ":") else { return (nil, text) }
        let head = String(text[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty, isLikelySenderHeader(head) else { return (nil, text) }
        return (head, tail)
    }

    /// Telefon satırlarını ayrı mesaj/gönderen bloklarına böler; böylece her mesaj oyun paketinde (`paket:gta-6`)
    /// tek başına eşleşip 0 ms'de çevrilebilir ve TV'de gönderen adı vurgulu ayrı balonlar olarak gösterilir.
    public static func extractMessages(from lines: [TextLine], in region: CropRegion) -> [Message] {
        let sorted = lines.sorted { ($0.box?.top ?? 0) < ($1.box?.top ?? 0) }
        guard !sorted.isEmpty else { return [] }

        let place = TextBox(left: region.left, top: region.top, right: region.right, bottom: region.bottom)
        let regionHeight = region.bottom - region.top
        let fallbackBox = TextBox(left: region.left, top: region.top, right: region.right, bottom: region.bottom)

        // Satırları dikey boşluğa veya yeni gönderen başlığına göre grupla.
        var groups: [(sender: String?, lines: [TextLine])] = []
        var pendingSender: String?
        var pendingSenderBox: TextBox?

        for line in sorted {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // Kısa gönderen adı satırı ("Brian") bir sonraki mesajın başlığı olur.
            if isLikelySenderHeader(text) {
                pendingSender = text
                pendingSenderBox = line.box
                continue
            }

            let inline = splitInlineSender(text)
            if let inlineSender = inline.sender {
                var bodyLine = line
                bodyLine.text = inline.body
                groups.append((sender: inlineSender, lines: [bodyLine]))
                pendingSender = nil
                pendingSenderBox = nil
                continue
            }

            if let sender = pendingSender {
                let isCloseToBody: Bool = {
                    guard let sBox = pendingSenderBox, let lBox = line.box else { return true }
                    let senderHeight = max(sBox.bottom - sBox.top, 0.02)
                    return (lBox.top - sBox.bottom) <= senderHeight * 1.35
                }()
                if isCloseToBody {
                    var first = line
                    if let sBox = pendingSenderBox, let lBox = line.box {
                        first.box = sBox.union(lBox)
                    }
                    groups.append((sender: sender, lines: [first]))
                    pendingSender = nil
                    pendingSenderBox = nil
                    continue
                } else {
                    // Arada büyük boşluk varsa üstteki satır sohbet göndereni değil, kart/e-posta başlığıdır.
                    groups.append((sender: nil, lines: [TextLine(sender, box: pendingSenderBox)]))
                    pendingSender = nil
                    pendingSenderBox = nil
                }
            }

            // Önceki gruba dikeyde yakınsa (aynı mesajın devam satırı) ekle; değilse yeni mesaj başlat.
            if let last = groups.last, let prevLine = last.lines.last,
               let prevBox = prevLine.box, let currBox = line.box {
                let lh = max(prevBox.bottom - prevBox.top, currBox.bottom - currBox.top, 0.02)
                let gap = currBox.top - prevBox.bottom
                if gap <= lh * 0.90 {
                    groups[groups.count - 1].lines.append(line)
                    continue
                }
            }
            groups.append((sender: nil, lines: [line]))
        }

        // Sonda yalnız kalmış bir gönderen/başlık varsa (ör. rehber/menü adı) kaybolmasın.
        if let lone = pendingSender {
            let box = pendingSenderBox.map { $0.placed(in: place) } ?? fallbackBox
            let lh = pendingSenderBox.map { ($0.bottom - $0.top) * regionHeight } ?? (0.04 * regionHeight)
            return groups.map { buildMessage($0.sender, $0.lines, place: place, regionHeight: regionHeight, fallbackBox: fallbackBox) }
                + [Message(sender: nil, body: lone, box: box, lineHeight: lh)]
        }

        return groups.map { buildMessage($0.sender, $0.lines, place: place, regionHeight: regionHeight, fallbackBox: fallbackBox) }
    }

    /// Telefon satırlarını analiz eder: ana ekran/kamera ikonlarıysa sessiz kalır (`.quiet`), sohbet uygulamasındaysa
    /// renkli gönderen balonları (`.chat`), uzun yazı/e-posta/sosyal medya ise tek düzenli cam okuma kartı (`.card`) döner.
    public static func parse(rawLines: [TextLine], in region: CropRegion, activeSubtitle: String?) -> Parsed {
        let hasChatCues = rawLines.contains { line in
            let lower = line.text.lowercased()
            return lower.contains("whatup") || lower.contains("encrypted") || lower.contains("members")
                || lower.contains("new message") || lower.contains("type a message")
        }
        let filtered = filterLines(rawLines, activeSubtitle: activeSubtitle)
        let messages = extractMessages(from: filtered, in: region)
        guard !messages.isEmpty else { return Parsed(layout: .quiet, messages: []) }

        // Sadece 1-2 kelimelik telefon ana ekran uygulama ikonlarından oluşuyorsa ekranı kirletme.
        let onlyHomeIcons = messages.allSatisfy { msg in
            let norm = msg.body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let words = norm.split(whereSeparator: \.isWhitespace)
            return msg.sender == nil && words.count <= 2 && homeIconWords.contains(norm)
        }
        if onlyHomeIcons {
            return Parsed(layout: .quiet, messages: [])
        }

        let hasSenders = messages.contains { $0.sender != nil }
        let layout: Layout = (hasSenders || hasChatCues) ? .chat : .card
        return Parsed(layout: layout, messages: messages)
    }

    private static func buildMessage(_ sender: String?, _ lines: [TextLine], place: TextBox,
                                     regionHeight: Double, fallbackBox: TextBox) -> Message {
        let body = ScreenTranslation.paragraphs(lines).joined(separator: "\n")
        let boxes = lines.compactMap(\.box)
        let box = boxes.dropFirst().reduce(boxes.first) { $0?.union($1) }?.placed(in: place) ?? fallbackBox
        let heights = boxes.map { ($0.bottom - $0.top) * regionHeight }.sorted()
        let lineHeight = heights.isEmpty ? (0.04 * regionHeight) : heights[heights.count / 2]
        let color = sender.map(colorHex(forSender:))
        return Message(sender: sender, senderColor: color, body: body, box: box, lineHeight: lineHeight)
    }
}
