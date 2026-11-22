// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Oyun içi telefon ekranından okunan metni temizler, ana altyazı sızıntısını ayıklar, sohbet başlığını/saatini,
/// gelen-giden (sol/sağ) baloncuk yönünü ve mesaj saatlerini çıkararak her mesajı ayrı kararlı bloklara böler.
///
/// GTA 6 gibi oyunlarda telefonun alt kenarına ana diyalog altyazısı sızabiliyor; ayrıca saat ("2:21 pm"),
/// şifreleme etiketi ("Messages encrypted") ve üye sayısı ("3 Members") gibi sabit telefon arayüzü yazıları
/// mesajla tek paragrafta yapıştığında oyun paketi (`paket:gta-6`) ıskalanıp yavaş internet çevirisine düşüyordu.
/// Artık bu üst bilgi ve zaman damgaları atılmak yerine TV'deki "İkiz Türkçe Telefon" görünümüne aktarılır.
public enum PhoneContent {
    /// Telefon ekranında açık olan uygulamanın görsel yerleşim kipi.
    public enum Layout: String, Codable, Equatable, Sendable {
        /// Mesajlaşma / WhatUp: gelen (sol) ve giden (sağ) baloncuklu gerçek sohbet akışı.
        case chat
        /// E-posta / haber / sosyal medya / uzun not: düzenli buzlu cam okuma kartı.
        case card
        /// Ana ekran ikonları / kamera / harita: çevrilecek cümle yok, TV sessiz kalır.
        case quiet
    }

    /// Mesaj balonunun sohbet içindeki yönü (ekrandaki yatay hizasından otomatik algılanır).
    public enum BubbleSide: String, Codable, Equatable, Sendable {
        /// Karşı taraftan gelen mesaj (sola yaslı).
        case incoming
        /// Oyuncunun gönderdiği mesaj (sağa yaslı).
        case outgoing
    }

    /// Telefonun üst durum çubuğu ve sohbet başlığı (kişi/grup adı, üye sayısı / durum, oyun içi saat).
    public struct Header: Equatable, Codable, Sendable {
        public var title: String?
        public var subtitle: String?
        public var clock: String?
        public var accentColor: String?

        public init(title: String? = nil, subtitle: String? = nil, clock: String? = nil, accentColor: String? = nil) {
            self.title = title
            self.subtitle = subtitle
            self.clock = clock
            self.accentColor = accentColor
        }

        public var isEmpty: Bool {
            (title ?? "").isEmpty && (subtitle ?? "").isEmpty && (clock ?? "").isEmpty
        }
    }

    public struct Parsed: Equatable, Sendable {
        public var layout: Layout
        public var header: Header?
        public var messages: [Message]

        public init(layout: Layout, header: Header? = nil, messages: [Message]) {
            self.layout = layout
            self.header = header
            self.messages = messages
        }
    }

    public struct Message: Equatable, Sendable {
        /// Kaydırma (scroll) sırasında aynı balonun TV'de titremeyip yumuşakça yer değiştirmesi için kararlı kimlik.
        public var stableId: String
        public var side: BubbleSide
        public var sender: String?
        public var senderColor: String?
        public var timestamp: String?
        public var dateLabel: String?
        public var body: String
        public var box: TextBox
        public var lineHeight: Double

        public init(stableId: String? = nil, side: BubbleSide = .incoming, sender: String?,
                    senderColor: String? = nil, timestamp: String? = nil, dateLabel: String? = nil,
                    body: String, box: TextBox, lineHeight: Double) {
            self.stableId = stableId ?? PhoneContent.stableMessageId(side: side, sender: sender, body: body)
            self.side = side
            self.sender = sender
            self.senderColor = senderColor
            self.timestamp = timestamp
            self.dateLabel = dateLabel
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

    /// Kaydırma sırasında noktalama/büyük-küçük harf farklarından etkilenmeyen kararlı mesaj kimliği (FNV-1a).
    public static func stableMessageId(side: BubbleSide, sender: String?, body: String) -> String {
        let normSender = TextMatch.normalize(sender ?? "")
        let normBody = TextMatch.normalize(body)
        let seed = "\(side.rawValue)|\(normSender)|\(normBody.prefix(64))"
        var hash: UInt64 = 14695981039346656037
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(format: "m_%012llx", hash & 0x0000_ffff_ffff_ffff)
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

    private static let pureTimeRegex = try! NSRegularExpression(
        pattern: #"^(\d{1,2}[:.]\d{2}(?:\s*[ap]\.?m\.?)?)$"#, options: [.caseInsensitive]
    )
    private static let trailingTimeRegex = try! NSRegularExpression(
        pattern: #"^(.*?)\s+(\d{1,2}[:.]\d{2}(?:\s*[ap]\.?m\.?)?)$"#, options: [.caseInsensitive]
    )

    /// Satır saf saat mi (`"2:21 pm"`, `"14:05"` vb.); öyleyse temiz saat metnini döner.
    public static func extractTimeString(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = String(trimmed.drop(while: { !$0.isNumber }))
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        guard !cleaned.isEmpty else { return nil }
        let ns = cleaned as NSString
        guard pureTimeRegex.firstMatch(in: cleaned, range: NSRange(location: 0, length: ns.length)) != nil else {
            return nil
        }
        return cleaned.replacingOccurrences(of: ".", with: ":")
    }

    /// Mesaj satırının sonuna yapışmış zaman damgasını ayırır (`"We're at the bar. 2:21 pm"` → gövde + saat).
    public static func splitTrailingTimestamp(_ text: String) -> (body: String, time: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = trimmed as NSString
        guard let match = trailingTimeRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges == 3 else {
            return (trimmed, nil)
        }
        let body = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        let time = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= 2 else { return (trimmed, nil) }
        return (body, time.replacingOccurrences(of: ".", with: ":"))
    }

    /// `"Today"` / `"Yesterday"` / `"Just now"` tarih ayırıcılarını Türkçeye çevirir.
    public static func localizedDateLabel(_ text: String) -> String? {
        let cleaned = text.drop(while: { !$0.isLetter && !$0.isNumber })
        let lower = cleaned.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        switch lower {
        case "today": return "Bugün"
        case "yesterday": return "Dün"
        case "just now", "now": return "Şimdi"
        default: return nil
        }
    }

    /// `"3 Members"`, `"Online"`, `"Messages encrypted"` gibi üst bilgi alt başlıklarını Türkçeleştirir.
    private static func localizedHeaderSubtitle(_ text: String) -> (text: String, priority: Int)? {
        let cleaned = text.drop(while: { !$0.isLetter && !$0.isNumber })
        let lower = cleaned.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if lower == "typing" { return ("Yazıyor…", 4) }
        if lower == "online" { return ("Çevrimiçi", 3) }
        if let range = lower.range(of: #"^(\d+)\s+members?$"#, options: .regularExpression) {
            let digits = lower[range].prefix(while: \.isNumber)
            return ("\(digits) Üye", 3)
        }
        if let range = lower.range(of: #"^(\d+)\s+notifications?$"#, options: .regularExpression) {
            let digits = lower[range].prefix(while: \.isNumber)
            return ("\(digits) Bildirim", 2)
        }
        if lower.contains("encrypted") { return ("Uçtan uca şifreli", 1) }
        return nil
    }

    /// `"Brian, Jason, Lucia"` gibi virgülle ayrılmış grup sohbeti başlığı mı.
    private static func isGroupTitleList(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(","), trimmed.count <= 48 else { return false }
        let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, parts.count <= 5 else { return false }
        return parts.allSatisfy { isLikelySenderHeader($0) }
    }

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
        var result = lines.filter { line in
            guard !isChrome(line.text) else { return false }
            // Kaydırma sırasında ekranın en üst/alt 4%'üne yarım sıkışmış çok kısa/düşük güvenli parçaları ele.
            if let box = line.box {
                let clippedEdge = box.bottom < 0.045 || box.top > 0.955
                let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if clippedEdge && (trimmed.count <= 4 || (line.confidence ?? 1) < 0.65) {
                    return false
                }
            }
            return true
        }
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

    /// İki satır aynı mesaj balonuna mı ait (dikey yakınlık + aynı yatay taraf + arada zaman damgası olmaması).
    private static func sameBubbleAlignment(_ a: TextBox, _ b: TextBox) -> Bool {
        let aRight = a.left >= 0.24 && a.right >= 0.72 && (a.left + a.right) / 2 >= 0.56 && (a.right - a.left) <= 0.75
        let bRight = b.left >= 0.24 && b.right >= 0.72 && (b.left + b.right) / 2 >= 0.56 && (b.right - b.left) <= 0.75
        if aRight != bRight { return false }
        // İki satır birbirine göre hem sol hem sağ kenardan belirgin biçimde ters yana kaymışsa ayrı baloncuktur.
        if (b.left - a.left >= 0.14 && b.right - a.right >= 0.14) || (a.left - b.left >= 0.14 && a.right - b.right >= 0.14) {
            return false
        }
        return true
    }

    private static func detectSide(sender: String?, localBoxes: [TextBox], colLeft: Double, colRight: Double) -> BubbleSide {
        // Gönderen başlığı olan baloncuklar karşı taraftan (gelen) gelir.
        if sender != nil { return .incoming }
        guard !localBoxes.isEmpty else { return .incoming }
        let minLeft = localBoxes.map(\.left).min() ?? 0
        let maxRight = localBoxes.map(\.right).max() ?? 1
        let centerX = (minLeft + maxRight) / 2
        let span = maxRight - minLeft
        // 1) Mutlak sağ hizalama (ekranda tek mesaj varken bile çalışır).
        if minLeft >= 0.24 && maxRight >= 0.72 && centerX >= 0.56 && span <= 0.75 {
            return .outgoing
        }
        // 2) Göreceli sohbet sütunu hizalaması: telefon kırpma kutusu geniş/kayık çizilmişse veya 2 satırlı giden
        //    mesaj biraz genişse bile sütunun sağ kenarına yaslanıp soldan boşluk bırakan balonlar giden sayılır.
        let colWidth = colRight - colLeft
        if colWidth >= 0.35 {
            let relLeft = (minLeft - colLeft) / colWidth
            let relRight = (maxRight - colLeft) / colWidth
            let relSpan = relRight - relLeft
            if relLeft >= 0.16 && relRight >= 0.90 && relSpan <= 0.84 {
                return .outgoing
            }
        }
        return .incoming
    }

    /// Telefon satırlarını ayrı mesaj/gönderen bloklarına böler; böylece her mesaj oyun paketinde (`paket:gta-6`)
    /// tek başına eşleşip 0 ms'de çevrilebilir ve TV'de gelen/giden baloncuk + zaman damgasıyla gösterilir.
    public static func extractMessages(from lines: [TextLine], in region: CropRegion) -> [Message] {
        extractMessagesInternal(from: lines, in: region, timeStamps: [], dateSeparators: []).map(\.message)
    }

    private struct BuiltGroup {
        var message: Message
        var localBox: TextBox?
    }

    private static func extractMessagesInternal(
        from lines: [TextLine],
        in region: CropRegion,
        timeStamps: [(text: String, box: TextBox)],
        dateSeparators: [(label: String, box: TextBox)]
    ) -> [BuiltGroup] {
        let sorted = lines.sorted { ($0.box?.top ?? 0) < ($1.box?.top ?? 0) }
        guard !sorted.isEmpty else { return [] }

        let place = TextBox(left: region.left, top: region.top, right: region.right, bottom: region.bottom)
        let regionHeight = region.bottom - region.top
        let fallbackBox = TextBox(left: region.left, top: region.top, right: region.right, bottom: region.bottom)

        // Satırları dikey boşluğa, yatay hizaya, aradaki saat/tarihe veya yeni gönderen başlığına göre grupla.
        var groups: [(sender: String?, senderBox: TextBox?, lines: [TextLine], inlineTime: String?)] = []
        var pendingSender: String?
        var pendingSenderBox: TextBox?

        for rawLine in sorted {
            let trimmed = rawLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let splitTime = splitTrailingTimestamp(trimmed)
            var line = rawLine
            line.text = splitTime.body

            // Kısa gönderen adı satırı ("Brian") bir sonraki mesajın başlığı olur.
            if splitTime.time == nil, isLikelySenderHeader(line.text) {
                pendingSender = line.text
                pendingSenderBox = line.box
                continue
            }

            let inline = splitInlineSender(line.text)
            if let inlineSender = inline.sender {
                var bodyLine = line
                bodyLine.text = inline.body
                groups.append((sender: inlineSender, senderBox: nil, lines: [bodyLine], inlineTime: splitTime.time))
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
                    // Gönderen kutusunu gövde satırının yüksekliğine ekleme: satır aralığı hesabı bozulmasın.
                    groups.append((sender: sender, senderBox: pendingSenderBox, lines: [line], inlineTime: splitTime.time))
                    pendingSender = nil
                    pendingSenderBox = nil
                    continue
                } else {
                    // Arada büyük boşluk varsa üstteki satır sohbet göndereni değil, kart/e-posta başlığıdır.
                    groups.append((sender: nil, senderBox: nil, lines: [TextLine(sender, box: pendingSenderBox)], inlineTime: nil))
                    pendingSender = nil
                    pendingSenderBox = nil
                }
            }

            // Önceki gruba dikeyde yakın, aynı tarafta ve arada zaman damgası yoksa aynı mesajın devam satırıdır.
            if let last = groups.last, let prevLine = last.lines.last,
               let prevBox = prevLine.box, let currBox = line.box {
                let lh = max(prevBox.bottom - prevBox.top, currBox.bottom - currBox.top, 0.02)
                let gap = currBox.top - prevBox.bottom
                let separatorBetween = timeStamps.contains { $0.box.top >= prevBox.bottom - 0.005 && $0.box.bottom <= currBox.top + 0.005 }
                    || dateSeparators.contains { $0.box.top >= prevBox.bottom - 0.005 && $0.box.bottom <= currBox.top + 0.005 }
                if gap <= lh * 0.90, sameBubbleAlignment(prevBox, currBox), !separatorBetween {
                    groups[groups.count - 1].lines.append(line)
                    if let t = splitTime.time { groups[groups.count - 1].inlineTime = t }
                    continue
                }
            }
            groups.append((sender: nil, senderBox: nil, lines: [line], inlineTime: splitTime.time))
        }

        // Sonda yalnız kalmış bir gönderen/başlık varsa (ör. rehber/menü adı) kaybolmasın.
        if let lone = pendingSender {
            groups.append((sender: nil, senderBox: nil, lines: [TextLine(lone, box: pendingSenderBox)], inlineTime: nil))
        }

        let allBoxes = groups.flatMap { $0.lines.compactMap(\.box) }
        let colLeft = allBoxes.map(\.left).min() ?? 0.08
        let colRight = allBoxes.map(\.right).max() ?? 0.92

        var built = groups.map { group -> BuiltGroup in
            let localBoxes = group.lines.compactMap(\.box)
            let bodyUnion = localBoxes.dropFirst().reduce(localBoxes.first) { $0?.union($1) }
            let localUnion = group.senderBox.flatMap { sb in bodyUnion.map { sb.union($0) } ?? sb } ?? bodyUnion
            let side = detectSide(sender: group.sender, localBoxes: localBoxes, colLeft: colLeft, colRight: colRight)
            let msg = buildMessage(group.sender, senderBox: group.senderBox, side: side, inlineTime: group.inlineTime,
                                   group.lines, place: place, regionHeight: regionHeight, fallbackBox: fallbackBox)
            return BuiltGroup(message: msg, localBox: localUnion)
        }

        // 1) Mesaj içi / balon altı saat damgalarını en yakın balona bağla.
        for stamp in timeStamps {
            var bestIdx: Int?
            var bestDist = Double.greatestFiniteMagnitude
            for idx in built.indices {
                guard built[idx].message.timestamp == nil, let lBox = built[idx].localBox else { continue }
                // Saat balonun içinde (sağ alt) ya da hemen altında (≤ 0.09) durur.
                guard stamp.box.top >= lBox.top - 0.02, stamp.box.top <= lBox.bottom + 0.09 else { continue }
                let dist = abs(stamp.box.top - lBox.bottom)
                if dist < bestDist {
                    bestDist = dist
                    bestIdx = idx
                }
            }
            if let idx = bestIdx {
                built[idx].message.timestamp = stamp.text
            }
        }

        // 2) "Bugün" / "Dün" tarih ayırıcılarını hemen altındaki ilk balona bağla.
        for sep in dateSeparators {
            if let idx = built.firstIndex(where: { ($0.localBox?.top ?? 1) >= sep.box.bottom - 0.015 }) {
                if built[idx].message.dateLabel == nil {
                    built[idx].message.dateLabel = sep.label
                }
            }
        }

        return built
    }

    /// Telefon satırlarını analiz eder: ana ekran/kamera ikonlarıysa sessiz kalır (`.quiet`), sohbet uygulamasındaysa
    /// başlık + saat + gelen/giden baloncuklar (`.chat`), uzun yazı/e-posta/sosyal medya ise düzenli cam kart (`.card`) döner.
    public static func parse(rawLines: [TextLine], in region: CropRegion, activeSubtitle: String?) -> Parsed {
        let sortedRaw = rawLines.sorted { ($0.box?.top ?? 0) < ($1.box?.top ?? 0) }
        let hasChatCues = sortedRaw.contains { line in
            let lower = line.text.lowercased()
            return lower.contains("whatup") || lower.contains("encrypted") || lower.contains("members")
                || lower.contains("new message") || lower.contains("type a message") || lower.contains("online")
        }

        // 1) Üst durum çubuğu saati, mesaj içi saatler, tarih ayırıcıları ve sohbet üst başlığını çıkar.
        var topClock: String?
        var headerSubtitle: (text: String, priority: Int)?
        var headerSubtitleTop: Double?
        var headerTitle: String?
        var consumedHeaderIndices: Set<Int> = []
        var chatTimestamps: [(text: String, box: TextBox)] = []
        var dateSeparators: [(label: String, box: TextBox)] = []

        for (idx, line) in sortedRaw.enumerated() {
            let box = line.box
            let top = box?.top ?? 0.5
            if let time = extractTimeString(line.text) {
                if top < 0.16 && topClock == nil {
                    topClock = time
                } else if let box {
                    chatTimestamps.append((time, box))
                }
                continue
            }
            if let date = localizedDateLabel(line.text), let box {
                dateSeparators.append((date, box))
                continue
            }
            if let sub = localizedHeaderSubtitle(line.text) {
                if headerSubtitle == nil || sub.priority > headerSubtitle!.priority {
                    headerSubtitle = sub
                    headerSubtitleTop = top
                }
                continue
            }
            // Üst bantta grup adı listesi ("Brian, Jason, Lucia") varsa bunu sohbet başlığı yap.
            if top < 0.24, headerTitle == nil, isGroupTitleList(line.text) {
                headerTitle = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                consumedHeaderIndices.insert(idx)
            }
        }

        // Üst bantta ("3 Members" / "Online" hemen üstünde) tek kişi/uygulama başlığı duruyorsa sohbet başlığına al.
        if headerTitle == nil, let subTop = headerSubtitleTop {
            for (idx, line) in sortedRaw.enumerated() where !consumedHeaderIndices.contains(idx) {
                guard let box = line.box, box.top < 0.22, box.bottom <= subTop + 0.02 else { continue }
                let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !isChrome(trimmed), isLikelySenderHeader(trimmed) else { continue }
                headerTitle = trimmed
                consumedHeaderIndices.insert(idx)
                break
            }
        }

        let remainingRaw = sortedRaw.enumerated().compactMap { idx, line in
            consumedHeaderIndices.contains(idx) ? nil : line
        }
        let filtered = filterLines(remainingRaw, activeSubtitle: activeSubtitle)
        let built = extractMessagesInternal(from: filtered, in: region,
                                            timeStamps: chatTimestamps, dateSeparators: dateSeparators)
        let messages = built.map(\.message)
        guard !messages.isEmpty else { return Parsed(layout: .quiet, header: nil, messages: []) }

        // Sadece 1-2 kelimelik telefon ana ekran uygulama ikonlarından oluşuyorsa ekranı kirletme.
        let onlyHomeIcons = messages.allSatisfy { msg in
            let norm = msg.body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let words = norm.split(whereSeparator: \.isWhitespace)
            return msg.sender == nil && words.count <= 2 && homeIconWords.contains(norm)
        }
        if onlyHomeIcons {
            return Parsed(layout: .quiet, header: nil, messages: [])
        }

        let hasSenders = messages.contains { $0.sender != nil }
        let hasOutgoing = messages.contains { $0.side == .outgoing }
        let hasMessageTimes = messages.contains { $0.timestamp != nil }
        let layout: Layout = (hasSenders || hasOutgoing || hasChatCues || hasMessageTimes) ? .chat : .card

        // Açık sohbet başlığı kırpıldıysa gelen gönderenlerden şık bir başlık türet ("Brian" / "Brian & Lucia").
        if layout == .chat && headerTitle == nil {
            var uniqueSenders: [String] = []
            for s in messages.compactMap(\.sender) where !uniqueSenders.contains(s) {
                uniqueSenders.append(s)
            }
            if !uniqueSenders.isEmpty {
                headerTitle = uniqueSenders.prefix(3).joined(separator: ", ")
            }
        }
        let accent = (headerTitle ?? messages.compactMap(\.sender).first).map(colorHex(forSender:))
        let builtHeader = Header(title: headerTitle, subtitle: headerSubtitle?.text, clock: topClock, accentColor: accent)
        let header = builtHeader.isEmpty ? nil : builtHeader

        return Parsed(layout: layout, header: header, messages: messages)
    }

    private static func buildMessage(_ sender: String?, senderBox: TextBox?, side: BubbleSide, inlineTime: String?,
                                     _ lines: [TextLine], place: TextBox,
                                     regionHeight: Double, fallbackBox: TextBox) -> Message {
        let body = ScreenTranslation.paragraphs(lines).joined(separator: "\n")
        let boxes = lines.compactMap(\.box)
        let bodyUnion = boxes.dropFirst().reduce(boxes.first) { $0?.union($1) }
        let combined = senderBox.flatMap { sb in bodyUnion.map { sb.union($0) } ?? sb } ?? bodyUnion
        let box = combined?.placed(in: place) ?? fallbackBox
        let heights = boxes.map { ($0.bottom - $0.top) * regionHeight }.sorted()
        let lineHeight = heights.isEmpty ? (0.04 * regionHeight) : heights[heights.count / 2]
        let color = sender.map(colorHex(forSender:))
        return Message(side: side, sender: sender, senderColor: color, timestamp: inlineTime,
                       body: body, box: box, lineHeight: lineHeight)
    }
}
