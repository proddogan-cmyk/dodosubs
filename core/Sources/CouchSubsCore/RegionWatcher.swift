// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Ek alanların çevirisini TV'ye ileten taraf (gerçekte `SubtitleServer`).
public protocol RegionSending: AnyObject {
    /// `text` boşsa alanın kutusu kalkar.
    func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?)
    /// Çevirinin içinde kumanda simgeleri varsa (`ButtonIcons`); simgeyi bilmeyen gönderici düz metni yollar.
    func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?)
    /// Alanda birbirinden ayrı duran yazı grupları varsa (görev başlığı ve ayrı sütundaki hedef) `blocks` her grubun
    /// çevirisini kendi yeriyle taşır; TV her birini kendi İngilizce yazısının üstüne koyar. Blokları bilmeyen gönderici
    /// birleşik metni yollar.
    func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                    blocks: [ScreenTranslation.Item]?)
    /// `presentation`: `.sideBubble` ise telefonun hemen yanında buzlu cam balon olarak gösterilir; `anchor` telefonun
    /// dış çerçeve konumudur. `options` tema, ölçek, uygulama düzeni ve shimmer bilgisini taşır.
    func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                    blocks: [ScreenTranslation.Item]?, presentation: RegionPresentation, anchor: TextBox?,
                    options: BubbleOptions)
    func clearRegions()
}

extension RegionSending {
    public func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?) {
        sendRegion(id: id, text: text, box: box, lineHeight: lineHeight)
    }

    public func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                           blocks: [ScreenTranslation.Item]?) {
        sendRegion(id: id, text: text, box: box, lineHeight: lineHeight, icons: icons)
    }

    public func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                           blocks: [ScreenTranslation.Item]?, presentation: RegionPresentation, anchor: TextBox?,
                           options: BubbleOptions = BubbleOptions()) {
        sendRegion(id: id, text: text, box: box, lineHeight: lineHeight, icons: icons, blocks: blocks)
    }
}

extension SubtitleServer: RegionSending {}

/// Ek alanları (görev yazısı, telefon mesajı, bildirim) ana altyazıdan ayrı ve seyrek okur, çevirip TV'ye kendi
/// yerleriyle gönderir (Windows: CouchSubs.Core/RegionWatcher.cs ile aynı kurallar).
///
/// - Ana okuma hattını beklemez, onu da bekletmez: `offer` hemen döner; tur ayrı bir görevde ve düşük öncelikle sürer.
/// - En çok `intervalMs`'te bir tur atılır; önceki tur (okuma ya da çeviri) bitmediyse kare atlanır.
/// - Bölge izi (`RegionCropper.signature`) değişmeyen alan yeniden okunmaz.
/// - Okunan yazı ancak kararlıysa çevrilir: iz bir tur değişmeden kaldıysa ya da iki okuma aynı yazıyı verdiyse (arkası
///   kıpırdayan köşe yazıları). Böylece belirirken yarım okunan yazı çevrilmez.
/// - Yazı değişmedikçe yeniden çevrilmez; boşalan alanın kutusu kalkar.
/// - Paket eşleşmesi ve çeviri motoru ana altyazıyla aynıdır; ama ek alan satırları ortak havuza önerilmez (arayüz
///   yazıları havuzu kirletmesin).
@MainActor
public final class RegionWatcher {
    /// Normal ek alanlar için iki tur arasındaki en kısa süre.
    public static let defaultIntervalMs = 1000
    /// `onlyWhenVisible` (telefon/panel) alanları için hızlı tarama aralığı: kapalıyken < 1 ms çerçeve kontrolü,
    /// açıldığında ve kapandığında ~5× daha hızlı tepki.
    public static let defaultFastIntervalMs = 200
    /// Telefon sallanırken tek karelik düşüşlerde kutunun titrememesi için kapanış onayı (ardışık kaç tur görünmez).
    public static let defaultCloseMisses = 3
    /// Gelen telefon mesajı/bildirim hızla kaybolursa kullanıcının okuyabilmesi için en az ekranda kalma süresi (ms).
    public static let defaultMinReadingHoldMs = 4200
    /// Kalıcı telefon önbelleğinde saklanacak en fazla satır sayısı.
    private static let maxCachedLines = 500
    /// Fade-in / hareket bulanıklığında düşük güvenli bozuk okumaları (ör. "Bren said o suttacad") elemek için eşik.
    private static let minPhoneConfidence = 0.78

    private struct State {
        var signature: [UInt8]?
        /// Telefon açıkken dış çerçeve arkasındaki 3B dünya hareket etse bile iç ekran değişmediyse OCR'ı atlamak için.
        var innerSignature: [UInt8]?
        /// Son okumanın sadeleştirilmiş yazısı; bir sonraki okuma aynıysa yazı kararlıdır.
        var lastRead: String?
        /// Okunmuş ama henüz kararlı sayılmamış yazı.
        var candidate: Candidate?
        /// TV'de şu an çevirisi duran yazı (sadeleştirilmiş); boşsa kutu yok.
        var shown = ""
        /// Mevcut çevirinin TV'de ilk gösterildiği zaman (ms); kısa bildirimleri okumaya süre tanımak için.
        var shownAt: Int?
        /// Panel kapandığında okuma süresi dolmadıysa bu zamana kadar balon ekranda tutulur.
        var holdUntil: Int?
        var holdTask: Task<Void, Never>?
        /// Düşük OCR güvenli bulanık kareleri kaç kez atladığımız (en fazla 2 kez bekler).
        var lowConfidenceRetries = 0
        /// Son gönderilen çeviri, aynı yazı yeni bir konuma taşındığında yeniden kullanılır.
        var renderedKey: String?
        var renderedText: String?
        var renderedIcons: [IconPlacement]?
        var renderedBox: TextBox?
        var renderedLineHeight: Double?
        var renderedLayout: [Block]?
        /// Gönderilen bloklar ve her birinin `Candidate.blocks` içindeki sırası.
        var renderedBlocks: [(group: Int, item: ScreenTranslation.Item)]?
        /// `onlyWhenVisible` açıkken son panel görünürlük sonucu (nil: henüz kontrol edilmedi).
        var panelVisible: Bool?
        /// Açık bir panelin ardışık kaç turda görünmez sayıldığı (el sallanmasında anlık titremeyi önler).
        var hiddenStreak = 0
        /// Telefon alttan yukarı kayarken bulanık ilk kareyi atlayıp sonraki net kareyi okumak için.
        var awaitingSettle = false
        /// TV'de şu an buzlu cam yükleniyor (shimmer) göstergesi açık mı.
        var showingLoading = false
        var lastOnlyWhenVisible = false
        var lastTemplates: [PanelTemplate] = []
        var lastThreshold: Double = PanelPresence.defaultThreshold
        var lastCropInnerScreen = true
        var lastBubbleTheme: BubbleTheme = .appleGlass
        var lastBubbleScale: Double = 1.0
        var lastPresentation: RegionPresentation = .overlay
        var lastPhoneLayout: PhoneContent.Layout?
        var lastPhoneHeader: PhoneContent.Header?
        /// Telefon açıkken kaydırma (scroll) boyunca görülen mesajların kimlik ve çeviri belleği.
        var recentThread: [ThreadMemory] = []
        /// Bu alanın en son ne zaman kontrol edildiği (ms).
        var lastVisit: Int?
    }

    private struct ThreadMemory {
        var msgId: String
        var side: PhoneContent.BubbleSide
        var sender: String?
        var normSource: String
        var translation: String
    }

    /// Alanda ayrı duran bir yazı grubu: `Candidate.paragraphs` içinde `start`'tan başlayan `count` parça, karedeki yeri
    /// ve satır yüksekliği (kareye oranla).
    struct Block: Equatable {
        var start: Int
        var count: Int
        var box: TextBox
        var lineHeight: Double
        var sender: String? = nil
        var senderColor: String? = nil
        var msgId: String? = nil
        var side: PhoneContent.BubbleSide? = nil
        var timestamp: String? = nil
        var dateLabel: String? = nil
    }

    struct Candidate {
        var paragraphs: [String]
        var box: TextBox?
        var lineHeight: Double?
        var key: String
        /// Her parçadaki kumanda simgeleri (kareden kesilmiş), parçadaki sırasıyla; simge yoksa nil.
        var icons: [[IconSlot]]? = nil
        /// Alanda birden çok ayrı yazı grubu varsa grupları; tek grupta nil (tek kutu).
        var blocks: [Block]? = nil
        /// Telefon mesajlarında her parçanın gönderen adı (paket aramasında ve TV balon başlığında kullanılır).
        var senders: [String?]? = nil
        /// Telefon uygulama düzeni (`.chat` / `.card` / `.quiet`).
        var phoneLayout: PhoneContent.Layout? = nil
        /// Telefon üst başlık bilgileri (kişi/grup adı, üye sayısı, oyun içi saat).
        var phoneHeader: PhoneContent.Header? = nil
    }

    private let reader: TextReader
    private let translator: TextTranslator
    private let server: RegionSending
    private let intervalMs: Int
    private let fastIntervalMs: Int
    private let closeMisses: Int
    private let minReadingHoldMs: Int
    private let cacheFile: URL?
    private let now: () -> Int
    private let panelDetector: @Sendable (CGImage, [PanelTemplate], Double) -> Bool
    private var states: [String: State] = [:]
    private var lastPass: Int?
    private var running: Task<Void, Never>?
    private var session = 0
    /// Kalıcı telefon çeviri önbelleği: aynı mesajlar ertesi gün bile 0 ms'de çeviri motoruna gitmeden döner.
    private var lineCache: [String: String] = [:]
    private var lineCacheOrder: [String] = []

    /// Oyun paketi: satırın hazır Türkçesi (ana altyazıyla aynı arama).
    public var packLookup: ((String) -> PackMatch?)?
    /// Ekranda o an gösterilen ana İngilizce diyalog altyazısı; telefon alanına sızarsa otomatik ayıklanır.
    public var activeSourceSubtitle: String?
    /// Hedef dil Türkçe: yüksek güvenle Türkçe olan parça çevrilmez, aslı sayılır (#289).
    public var skipsTurkish = true
    public var onLog: ((String) -> Void)?
    /// Her okumanın süresi (ms; ölçüm için).
    public var onReadMs: ((Int) -> Void)?
    /// `onlyWhenVisible` açık bir alanın görünürlüğü değişince çağrılır (`id`, `görünür mü`).
    public var onPanelVisibility: ((String, Bool) -> Void)?
    /// Tamamlanan tur sayısı ve okuma sayısı (ölçüm ve testler için).
    public private(set) var passes = 0
    public private(set) var reads = 0

    public init(reader: TextReader, translator: TextTranslator, server: RegionSending,
                intervalMs: Int = RegionWatcher.defaultIntervalMs,
                fastIntervalMs: Int = RegionWatcher.defaultFastIntervalMs,
                closeMisses: Int = RegionWatcher.defaultCloseMisses,
                minReadingHoldMs: Int = RegionWatcher.defaultMinReadingHoldMs,
                cacheFile: URL? = nil,
                clock: @escaping () -> Int = SubtitleStabilizer.uptimeMs,
                panelDetector: @escaping @Sendable (CGImage, [PanelTemplate], Double) -> Bool = {
                    PanelPresence.isVisible($0, templates: $1, threshold: $2)
                }) {
        self.reader = reader
        self.translator = translator
        self.server = server
        self.intervalMs = intervalMs
        self.fastIntervalMs = min(intervalMs, fastIntervalMs)
        self.closeMisses = max(1, closeMisses)
        self.minReadingHoldMs = max(0, minReadingHoldMs)
        self.cacheFile = cacheFile
        self.now = clock
        self.panelDetector = panelDetector
        loadPersistentCache()
    }

    /// Bir tur sürüyor mu.
    public var isBusy: Bool { running != nil }

    /// Şu an ekranda görünür durumda olan `onlyWhenVisible` (telefon/panel) alanlarının ekran kutuları (0–1).
    /// Ana altyazı hattı bu kutuların içine düşen satırları eleyerek telefon → altyazı sızıntısını önler.
    public func activePanelBoxes(for areas: [ExtraArea]) -> [TextBox] {
        areas.compactMap { area in
            guard area.onlyWhenVisible, states[area.id]?.panelVisible == true else { return nil }
            let r = area.region
            return TextBox(left: r.left, top: r.top, right: r.right, bottom: r.bottom)
        }
    }

    /// Her karede çağrılır; tur zamanı geldiyse ve önceki tur bittiyse turu arka planda başlatır, hemen döner.
    /// `onlyWhenVisible` açık (telefon/panel) alanlar `fastIntervalMs` (250 ms), normal alanlar `intervalMs` (1000 ms)
    /// aralıkla kontrol edilir.
    public func offer(_ frame: CGImage, areas: [ExtraArea]) {
        guard running == nil else { return }
        let ids = Set(areas.map(\.id))
        let hasRemoved = states.keys.contains { !ids.contains($0) }
        guard !areas.isEmpty || hasRemoved else { return }

        let time = now()
        let dueAreas = areas.filter { area in
            let step = area.onlyWhenVisible ? fastIntervalMs : intervalMs
            guard let last = states[area.id]?.lastVisit else { return true }
            return time - last >= step
        }
        guard !dueAreas.isEmpty || hasRemoved else { return }

        lastPass = time
        for area in dueAreas {
            if states[area.id] == nil { states[area.id] = State() }
            states[area.id]?.lastVisit = time
        }
        let session = self.session
        running = Task { [weak self] in
            await self?.runPass(frame, dueAreas: dueAreas, activeIDs: ids)
            // Bu arada sıfırlandıysa yeni oturumun turuna dokunulmaz.
            if self?.session == session { self?.running = nil }
        }
    }

    /// Bir tur: kaldırılan alanların kutusu kalkar, her açık alan gerekirse okunur ve kararlı yazısı çevrilir.
    /// Testler doğrudan çağırır.
    public func pass(_ frame: CGImage, areas: [ExtraArea]) async {
        await runPass(frame, dueAreas: areas, activeIDs: Set(areas.map(\.id)))
    }

    private func runPass(_ frame: CGImage, dueAreas: [ExtraArea], activeIDs: Set<String>) async {
        let started = session
        passes += 1
        for (id, state) in states where !activeIDs.contains(id) {
            if !state.shown.isEmpty { server.sendRegion(id: id, text: "", box: nil, lineHeight: nil) }
            states[id] = nil
        }
        for area in dueAreas {
            await visit(area, frame: frame)
            guard session == started else { return }
        }
    }

    private func visit(_ area: ExtraArea, frame: CGImage) async {
        let region = area.region
        let ocrRegion = area.ocrRegion
        let (crop, signature) = await Task.detached(priority: .utility) {
            let crop = RegionCropper.crop(frame, to: region)
            return (crop, RegionCropper.signature(of: crop))
        }.value
        var state = states[area.id] ?? State()
        let previousSignature = state.signature
        let changed = previousSignature.map {
            ReadScheduler.changed($0, signature, threshold: ReadScheduler.defaultChangeThreshold)
        } ?? true
        state.signature = signature

        let styleChanged = state.lastBubbleTheme != area.bubbleTheme
            || abs(state.lastBubbleScale - area.bubbleScale) > 1e-4
            || state.lastPresentation != area.presentation
        state.lastBubbleTheme = area.bubbleTheme
        state.lastBubbleScale = area.bubbleScale
        state.lastPresentation = area.presentation

        // Kullanıcı Ayarlar'dan tema/boyut değiştirdiyse TV'deki açık telefon balonunu anında güncelle!
        if styleChanged, !state.shown.isEmpty, let renderedText = state.renderedText, !renderedText.isEmpty {
            let anchor = TextBox(left: area.region.left, top: area.region.top, right: area.region.right, bottom: area.region.bottom)
            let opts = BubbleOptions(theme: area.bubbleTheme, scale: area.bubbleScale, layout: state.lastPhoneLayout,
                                     loading: false, phoneHeader: state.lastPhoneHeader)
            server.sendRegion(id: area.id, text: renderedText, box: state.renderedBox, lineHeight: state.renderedLineHeight,
                              icons: state.renderedIcons, blocks: state.renderedBlocks?.map(\.item),
                              presentation: area.presentation, anchor: anchor, options: opts)
        }

        let visibilitySettingsChanged = state.lastOnlyWhenVisible != area.onlyWhenVisible
            || state.lastTemplates != area.panelTemplates
            || abs(state.lastThreshold - area.panelThreshold) > 1e-6
            || state.lastCropInnerScreen != area.cropInnerScreen
        var becameVisible = false
        if area.onlyWhenVisible {
            if changed || visibilitySettingsChanged || state.panelVisible == nil || state.awaitingSettle {
                let session = self.session
                let detector = self.panelDetector
                let templates = area.panelTemplates
                let threshold = area.panelThreshold
                let visible = await Task.detached(priority: .utility) {
                    detector(crop, templates, threshold)
                }.value
                guard session == self.session else { return }
                let previous = state.panelVisible
                state.lastOnlyWhenVisible = true
                state.lastTemplates = templates
                state.lastThreshold = threshold
                state.lastCropInnerScreen = area.cropInnerScreen
                if !visible {
                    // Telefon açıkken el sallanması veya anlık parlamada tek kare düşüşle kutuyu silme:
                    // ardışık `closeMisses` tur görünmez kalırsa gerçekten kapanmış sayılır.
                    if previous == true {
                        state.hiddenStreak += 1
                        if state.hiddenStreak < closeMisses {
                            states[area.id] = state
                            return
                        }
                    }
                    state.hiddenStreak = 0
                    state.awaitingSettle = false
                    state.panelVisible = false
                    if previous != false {
                        onPanelVisibility?(area.id, false)
                    }
                    state.lastRead = nil
                    state.candidate = nil
                    if !state.shown.isEmpty || state.showingLoading {
                        // Kısa mesaj/bildirim ekrandan hızlıca kaybolduysa kullanıcının okuyabilmesi için
                        // minimum okuma süresi (4.2–7.5 sn) dolana kadar balonu ekranda tut.
                        if !state.shown.isEmpty, let shownAt = state.shownAt, minReadingHoldMs > 0 {
                            let holdMs = Self.readingHoldMs(for: state.renderedText ?? "", baseMs: minReadingHoldMs)
                            let target = shownAt + holdMs
                            let remaining = target - now()
                            if remaining > 0 {
                                let justStartedHold = state.holdUntil == nil
                                state.holdUntil = target
                                state.showingLoading = false
                                if justStartedHold, area.presentation == .sideBubble,
                                   let renderedText = state.renderedText, !renderedText.isEmpty {
                                    let anchor = TextBox(left: area.region.left, top: area.region.top, right: area.region.right, bottom: area.region.bottom)
                                    let opts = BubbleOptions(theme: area.bubbleTheme, scale: area.bubbleScale,
                                                             layout: state.lastPhoneLayout, loading: false, holdMs: remaining,
                                                             phoneHeader: state.lastPhoneHeader)
                                    server.sendRegion(id: area.id, text: renderedText, box: state.renderedBox,
                                                      lineHeight: state.renderedLineHeight, icons: state.renderedIcons,
                                                      blocks: state.renderedBlocks?.map(\.item),
                                                      presentation: .sideBubble, anchor: anchor, options: opts)
                                }
                                if state.holdTask == nil {
                                    let session = self.session
                                    let id = area.id
                                    let name = area.name
                                    state.holdTask = Task { [weak self] in
                                        try? await Task.sleep(for: .milliseconds(remaining))
                                        guard let self, self.session == session else { return }
                                        self.expireHold(id: id, name: name)
                                    }
                                }
                                states[area.id] = state
                                return
                            }
                        }
                        clearVisibleState(&state, id: area.id, name: area.name)
                    }
                    states[area.id] = state
                    return
                }
                state.hiddenStreak = 0
                state.holdUntil = nil
                state.holdTask?.cancel()
                state.holdTask = nil
                state.panelVisible = true
                if previous != true {
                    onPanelVisibility?(area.id, true)
                    becameVisible = true
                    onLog?("ek alan \(area.name): panel algılandı")
                    // Telefon kapalıyken hızla alttan yukarı kayıyorsa (yüksek kare farkı), bulanık animasyon karesini
                    // OCR'a sokup çöp üretmek yerine 1 hızlı tur (200 ms) oturmasını bekle; bu sırada buzlu cam nabız göster.
                    if previous == false, let prevSig = previousSignature,
                       Self.meanDiff(prevSig, signature) > 30, !area.panelTemplates.isEmpty {
                        state.awaitingSettle = true
                        if area.presentation == .sideBubble, state.shown.isEmpty {
                            let anchor = TextBox(left: area.region.left, top: area.region.top, right: area.region.right, bottom: area.region.bottom)
                            let opts = BubbleOptions(theme: area.bubbleTheme, scale: area.bubbleScale, layout: nil, loading: true)
                            server.sendRegion(id: area.id, text: "", box: anchor, lineHeight: nil, icons: nil, blocks: nil,
                                              presentation: .sideBubble, anchor: anchor, options: opts)
                            state.showingLoading = true
                        }
                        states[area.id] = state
                        return
                    }
                }
            } else if state.panelVisible == false {
                if let holdUntil = state.holdUntil, now() >= holdUntil {
                    clearVisibleState(&state, id: area.id, name: area.name)
                }
                states[area.id] = state
                return
            }
        } else if state.lastOnlyWhenVisible {
            state.panelVisible = nil
            state.hiddenStreak = 0
            state.awaitingSettle = false
            state.showingLoading = false
            state.lastOnlyWhenVisible = false
            state.lastTemplates = []
            state.lastThreshold = PanelPresence.defaultThreshold
            state.lastCropInnerScreen = area.cropInnerScreen
            onPanelVisibility?(area.id, true)
        }

        let settledNow = state.awaitingSettle
        state.awaitingSettle = false

        guard changed || becameVisible || settledNow || visibilitySettingsChanged else {
            // İz bir tur değişmedi: okunan yazı kararlıdır.
            if let candidate = state.candidate {
                state.candidate = nil
                states[area.id] = state
                await commit(candidate, area: area)
            } else {
                states[area.id] = state
            }
            return
        }
        let started = now()
        let session = self.session
        let reader = self.reader
        let useInner = ocrRegion != region
        let useHybridFast = area.onlyWhenVisible && (reader is VisionReader)
        let checkInnerGate = area.onlyWhenVisible && useInner && !state.shown.isEmpty && !becameVisible && !settledNow && !visibilitySettingsChanged
        let prevInnerSig = state.innerSignature

        let (ocrCrop, innerSig, innerUnchanged, firstReading) = await Task.detached(priority: .utility) { () -> (CGImage, [UInt8]?, Bool, Reading?) in
            let cropped = useInner ? RegionCropper.crop(frame, to: ocrRegion) : crop
            var computedInner: [UInt8]? = nil
            if useInner, area.onlyWhenVisible {
                let sig = RegionCropper.signature(of: cropped)
                computedInner = sig
                // Telefonun dış köşelerindeki oyun dünyası hareket etse bile iç ekran değişmediyse OCR çalıştırma!
                if checkInnerGate, let prev = prevInnerSig, !ReadScheduler.changed(prev, sig, threshold: 12) {
                    return (cropped, sig, true, nil)
                }
            }
            return (cropped, computedInner, false, try? reader.readLines(cropped, deep: false, fast: useHybridFast))
        }.value
        guard session == self.session else { return }
        if let innerSig { state.innerSignature = innerSig }
        if innerUnchanged {
            states[area.id] = state
            return
        }
        guard var reading = firstReading else {
            // OCR hatası boş alan değildir. Eski kutuyu koru; aynı kareyi sonraki normal turda yeniden oku.
            // Başarısız kare, önceki adayın kararlılığını da doğrulayamaz.
            state.signature = nil
            state.innerSignature = nil
            state.lastRead = nil
            state.candidate = nil
            states[area.id] = state
            return
        }
        var candidate = area.onlyWhenVisible
            ? Self.phoneCandidate(reading, in: ocrRegion, frame: ocrCrop, activeSubtitle: activeSourceSubtitle, skipsTurkish: skipsTurkish)
            : Self.candidate(reading, in: ocrRegion, frame: ocrCrop)

        // Çift-hızlı hibrit OCR: `.fast` (~20 ms, CoreImage yükü olmadan) okumasında tüm satırlar oyun paketinden veya
        // önbellekten çözülebildiyse ağır `.accurate` + 2× büyütme hiç çalışmaz. Eksik satır varsa yalnız o zaman
        // 2× büyütme + keskinleştirme + `.accurate` çalışır (~%90 daha az GPU/CPU yükü!).
        if useHybridFast {
            let prepared = candidate.paragraphs.map(IconText.protect)
            let resolved = resolveImmediate(candidate.paragraphs, prepared: prepared, senders: candidate.senders)
            let allInstant = !candidate.paragraphs.isEmpty && resolved.allSatisfy { $0 != nil }
            if !allInstant {
                if let accurate = await Task.detached(priority: .utility, operation: {
                    let enhanced = VisionReader.enhanceSmallText(ocrCrop)
                    return try? reader.readLines(enhanced, deep: false, fast: false)
                }).value {
                    guard session == self.session else { return }
                    reading = accurate
                    candidate = Self.phoneCandidate(reading, in: ocrRegion, frame: ocrCrop, activeSubtitle: activeSourceSubtitle, skipsTurkish: skipsTurkish)
                }
            }
        }
        reads += 1
        onReadMs?(now() - started)

        // Fade-in / bulanık ilk kare koruması: telefon/bildirim açılırken OCR güveni düşükse (< 0.78) bozuk metni
        // çevirmene yollayıp anlamsız Türkçe göstermek yerine en fazla 2 hızlı tur (200 ms) netleşmesini bekle.
        if area.onlyWhenVisible, !candidate.key.isEmpty,
           let confidence = reading.confidence, confidence < Self.minPhoneConfidence,
           state.lowConfidenceRetries < 2 {
            state.lowConfidenceRetries += 1
            state.awaitingSettle = true
            states[area.id] = state
            return
        }
        state.lowConfidenceRetries = 0
        // Tanıtılmış bir telefon/panel açıkken (ya da ekranda zaten telefon çevirisi varken yeni mesaja geçildiğinde)
        // 2. kararlılık turunu beklemeden ilk okumada anında çevir: açılış ve kaydırma gecikmesini yarıya indirir.
        let instantCommit = area.onlyWhenVisible && !candidate.key.isEmpty
            && (!area.panelTemplates.isEmpty || !state.shown.isEmpty)
        if instantCommit || state.lastRead == candidate.key {
            state.lastRead = candidate.key
            state.candidate = nil
            states[area.id] = state
            await commit(candidate, area: area)
        } else {
            state.lastRead = candidate.key
            state.candidate = candidate
            states[area.id] = state
        }
    }

    /// Telefon/panel okumasından temiz mesaj adayları üretir:
    /// - Saat, şifreleme etiketi, üye/bildirim sayacı gibi telefon arayüzü gürültülerini atar.
    /// - Ekranda o an gösterilen ana diyalog altyazısının telefon kutusuna sızmasını engeller.
    /// - Her mesajı ayrı blok ve gönderen başlığı (`sender`) olarak ayırır; böylece her mesaj `paket` içinde
    ///   tek başına 0 ms'de eşleşir ve TV'de ayrı buzlu cam konuşma balonu olarak görünür.
    static func phoneCandidate(_ reading: Reading, in region: CropRegion, frame: CGImage? = nil,
                               activeSubtitle: String? = nil, skipsTurkish: Bool = true) -> Candidate {
        let rawLines = reading.withButtonIcons().withoutButtonPrompts().withoutOcrNoise().lines
            .filter { ScreenTranslation.isWords($0.text) || PhoneContent.extractTimeString($0.text) != nil }
            .sorted { ($0.box?.top ?? 0) < ($1.box?.top ?? 0) }
        if SystemOverlayFilter.isSystemOverlay(rawLines.map(\.text)) {
            return Candidate(paragraphs: [], box: nil, lineHeight: nil, key: "", icons: nil, blocks: nil,
                             senders: nil, phoneLayout: .quiet, phoneHeader: nil)
        }
        let parsed = PhoneContent.parse(rawLines: rawLines, in: region, activeSubtitle: activeSubtitle)
        let messages = parsed.messages
        guard parsed.layout != .quiet, !messages.isEmpty else {
            return Candidate(paragraphs: [], box: nil, lineHeight: nil, key: "", icons: nil, blocks: nil,
                             senders: nil, phoneLayout: .quiet, phoneHeader: parsed.header)
        }
        let paragraphs = messages.map(\.body)
        if SystemOverlayFilter.isSystemOverlay(paragraphs)
            || (skipsTurkish && paragraphs.allSatisfy { TurkishText.isSure($0) }) {
            return Candidate(paragraphs: [], box: nil, lineHeight: nil, key: "", icons: nil, blocks: nil,
                             senders: nil, phoneLayout: .quiet, phoneHeader: nil)
        }
        let senders = messages.map(\.sender)
        let box = messages.map(\.box).dropFirst().reduce(messages.first?.box) { $0?.union($1) }
        let heights = messages.map(\.lineHeight).sorted()
        let lineHeight = heights.isEmpty ? nil : heights[heights.count / 2]
        let blocks = messages.enumerated().map { index, msg in
            Block(start: index, count: 1, box: msg.box, lineHeight: msg.lineHeight,
                  sender: msg.sender, senderColor: msg.senderColor,
                  msgId: msg.stableId, side: msg.side, timestamp: msg.timestamp, dateLabel: msg.dateLabel)
        }
        let key = TextMatch.normalize(paragraphs.joined(separator: " ")) + "|p" + String(blocks.count)
        return Candidate(paragraphs: paragraphs, box: box, lineHeight: lineHeight, key: key,
                         icons: nil, blocks: blocks, senders: senders,
                         phoneLayout: parsed.layout, phoneHeader: parsed.header)
    }

    private static func meanDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var sum = 0
        for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count)
    }

    /// Okumadan çevrilecek parçalar: kumanda ipuçları, yazı tanıma çöpleri ve harfsiz göstergeler ("23m", "9") atılır;
    /// satırlar yukarıdan aşağı parçalara toplanır (başlık, cümle, madde). Yazının içindeki kumanda simgeleri `frame`'den
    /// (okunan alan) kesilir; çeviride yerleri korunur.
    static func candidate(_ reading: Reading, in region: CropRegion, frame: CGImage? = nil) -> Candidate {
        let lines = reading.withButtonIcons().withoutButtonPrompts().withoutOcrNoise().lines
            .filter { ScreenTranslation.isWords($0.text) }
            .sorted { ($0.box?.top ?? 0) < ($1.box?.top ?? 0) }
        var paragraphs = ScreenTranslation.paragraphs(lines)
        let place = TextBox(left: region.left, top: region.top, right: region.right, bottom: region.bottom)
        let boxes = lines.compactMap(\.box)
        let box = boxes.dropFirst().reduce(boxes.first) { $0?.union($1) }?.placed(in: place)
        let height = region.bottom - region.top
        let heights = boxes.map { ($0.bottom - $0.top) * height }.sorted()
        let lineHeight = heights.isEmpty ? nil : heights[heights.count / 2]
        var key = TextMatch.normalize(paragraphs.joined(separator: " "))
        var icons = ScreenTranslation.paragraphIcons(lines)
        // Alanda birbirinden ayrı duran yazılar (başlık ile ayrı sütundaki hedef, alt alta iki bildirim) "Ekranı çevir"deki
        // gibi gruplanır; her grubun çevirisi TV'de kendi yerine konur. Tek grupta (ya da yeri bilinmeyen satır varsa)
        // eskisi gibi tek kutu. Anahtar grup yapısını da içerir: aynı yazı farklı gruplanırsa bloklar yeniden kurulur.
        var blocks: [Block]?
        let groups = lines.count > 1 && boxes.count == lines.count ? ScreenTranslation.groups(reading) : []
        if groups.count > 1, groups.count < ScreenTranslation.maxGroups {
            paragraphs = groups.flatMap(\.paragraphs)
            icons = groups.flatMap { $0.icons ?? $0.paragraphs.map { _ in [IconSlot]() } }
            var list: [Block] = []
            var start = 0
            for group in groups {
                list.append(Block(start: start, count: group.paragraphs.count, box: group.box.placed(in: place),
                                  lineHeight: group.lineHeight * height))
                start += group.paragraphs.count
            }
            blocks = list
            key = TextMatch.normalize(paragraphs.joined(separator: " ")) + "|" + list.map { String($0.count) }.joined(separator: ",")
        }
        var cut: [[IconSlot]]?
        if let frame, icons.contains(where: { !$0.isEmpty }) {
            cut = icons.map { ButtonIcons.withImages($0, frame: frame) }
        }
        return Candidate(paragraphs: paragraphs, box: box, lineHeight: lineHeight, key: key, icons: cut, blocks: blocks)
    }

    /// Kararlı yazı: öncekinden farklıysa çevrilip gönderilir, boşsa kutu kalkar.
    private func commit(_ rawCandidate: Candidate, area: ExtraArea) async {
        guard var state = states[area.id] else { return }
        // Telefon kaydırılırken aynı mesaj 1 harf OCR farkıyla gelse bile aynı `msgId` ve 0 ms çeviri belleğini koru;
        // üst başlık (saat / grup adı / üye sayısı) kaydırma sırasında kaybolursa son geçerli başlığı sürdür.
        var candidate = rawCandidate
        let threadHits: [Int: String]
        if area.onlyWhenVisible, !candidate.paragraphs.isEmpty {
            candidate.phoneHeader = Self.mergeHeader(new: candidate.phoneHeader, previous: state.lastPhoneHeader)
            let stabilized = Self.stabilizeScrollCandidate(candidate, memory: state.recentThread)
            candidate = stabilized.candidate
            threadHits = stabilized.translations
        } else {
            threadHits = [:]
        }

        let headerChanged = area.onlyWhenVisible && candidate.phoneHeader != state.lastPhoneHeader
        let sameText = state.shown == candidate.key
            || (area.onlyWhenVisible && !state.shown.isEmpty && !candidate.key.isEmpty
                && TextMatch.isSimilar(Self.plainKey(state.shown), Self.plainKey(candidate.key), threshold: 0.90))
        if sameText {
            guard let renderedText = state.renderedText, !renderedText.isEmpty else { return }
            // Telefon/yan balon modunda el sallanmasından gelen küçük (< %3.5) konum oynamalarını yok say
            // (saat veya başlık değişmediyse balonlar sabit ve titreşimsiz durur).
            if !headerChanged, area.presentation == .sideBubble || area.onlyWhenVisible,
               Self.isSmallJitter(state.renderedBox, candidate.box, tolerance: 0.035) {
                return
            }
            guard headerChanged || state.renderedKey == candidate.key else { return }
            guard headerChanged || state.renderedBox != candidate.box || state.renderedLineHeight != candidate.lineHeight
                    || state.renderedLayout != candidate.blocks else { return }
            // Aynı yazı kaydı: çeviriler korunur, bloklar yeni yerlerine taşınır (anahtar aynıysa grup sayısı da aynıdır).
            var moved: [(group: Int, item: ScreenTranslation.Item)]?
            if let rendered = state.renderedBlocks, let current = candidate.blocks {
                moved = rendered.map { block -> (group: Int, item: ScreenTranslation.Item) in
                    var item = block.item
                    if block.group < current.count {
                        item.box = current[block.group].box
                        item.lineHeight = current[block.group].lineHeight
                        if let t = current[block.group].timestamp { item.timestamp = t }
                        if let d = current[block.group].dateLabel { item.dateLabel = d }
                    }
                    return (block.group, item)
                }
            }
            let anchor = TextBox(left: area.region.left, top: area.region.top, right: area.region.right, bottom: area.region.bottom)
            let opts = BubbleOptions(theme: area.bubbleTheme, scale: area.bubbleScale, layout: candidate.phoneLayout,
                                     loading: false, phoneHeader: candidate.phoneHeader)
            server.sendRegion(id: area.id, text: renderedText, box: candidate.box, lineHeight: candidate.lineHeight,
                              icons: state.renderedIcons, blocks: moved?.map(\.item),
                              presentation: area.presentation, anchor: anchor, options: opts)
            state.renderedBox = candidate.box
            state.renderedLineHeight = candidate.lineHeight
            state.renderedLayout = candidate.blocks
            state.renderedBlocks = moved
            state.lastPhoneHeader = candidate.phoneHeader
            states[area.id] = state
            return
        }
        let previousShown = state.shown
        states[area.id]?.shown = candidate.key
        guard !candidate.key.isEmpty else {
            if !previousShown.isEmpty || state.showingLoading {
                server.sendRegion(id: area.id, text: "", box: nil, lineHeight: nil)
            }
            states[area.id]?.showingLoading = false
            states[area.id]?.renderedKey = candidate.key
            states[area.id]?.renderedText = ""
            states[area.id]?.renderedIcons = nil
            states[area.id]?.renderedBox = nil
            states[area.id]?.renderedLineHeight = nil
            onLog?("ek alan \(area.name): boşaldı")
            return
        }
        let session = self.session
        // Simgeler paket aramasında yok sayılır, çeviride uydurma adlarla korunur (`IconText`).
        let prepared = candidate.paragraphs.map(IconText.protect)
        let anchor = TextBox(left: area.region.left, top: area.region.top, right: area.region.right, bottom: area.region.bottom)

        // 1) Önce paketten + Türkçe kontrolünden + oturum önbelleğinden + kaydırma belleğinden 0 ms'de çözülebilenleri bul.
        var translated = resolveImmediate(candidate.paragraphs, prepared: prepared, senders: candidate.senders)
        for (idx, cachedHit) in threadHits where idx < translated.count && translated[idx] == nil {
            translated[idx] = cachedHit
        }
        let fromPack = translated.indices.filter { translated[$0] != nil }.count
        let missing = translated.indices.filter { translated[$0] == nil }

        // 2) Kademeli Akış (Progressive Render) & Buzlu Cam Shimmer:
        // Bazı mesajlar zaten paketten/bellekten hazırsa hemen ekrana bas; hiçbiri hazır değilse motor beklenirken shimmer aç.
        if !missing.isEmpty, area.presentation == .sideBubble {
            let readyCount = translated.compactMap { $0 }.count
            if readyCount > 0 {
                sendCandidate(candidate, area: area, prepared: prepared, translated: translated,
                              anchor: anchor, loading: true, onlyTranslated: true)
                states[area.id]?.showingLoading = true
            } else if previousShown.isEmpty {
                let opts = BubbleOptions(theme: area.bubbleTheme, scale: area.bubbleScale, layout: candidate.phoneLayout,
                                         loading: true, phoneHeader: candidate.phoneHeader)
                server.sendRegion(id: area.id, text: "", box: candidate.box ?? anchor, lineHeight: candidate.lineHeight,
                                  icons: nil, blocks: nil, presentation: .sideBubble, anchor: anchor, options: opts)
                states[area.id]?.showingLoading = true
            }
        }

        // 3) Karakter adlarını çevirmene öğret (çeviride özel adlar bozulmaz) ve eksik satırları çevir.
        if let senders = candidate.senders {
            for sender in senders.compactMap({ $0 }) { translator.noteSpeaker(sender) }
        }
        if !missing.isEmpty {
            do {
                let texts = missing.map { prepared[$0].text }
                let fetched = translator.translatesTogether ? try await translator.translateAll(texts)
                    : try await sequential(texts)
                guard session == self.session, states[area.id]?.shown == candidate.key else { return }
                for (index, value) in zip(missing, fetched) {
                    translated[index] = value
                    rememberTranslation(prepared[index].text, value)
                }
                savePersistentCache()
            } catch {
                guard session == self.session else { return }
                if states[area.id]?.shown == candidate.key {
                    states[area.id]?.shown = previousShown
                    states[area.id]?.candidate = candidate
                }
                if states[area.id]?.showingLoading == true, previousShown.isEmpty {
                    states[area.id]?.showingLoading = false
                    server.sendRegion(id: area.id, text: "", box: nil, lineHeight: nil)
                }
                onLog?("ek alan \(area.name): \(SubtitleLog.excerpt(IconText.plain(candidate.paragraphs.joined(separator: " ")))) çevrilemedi (\(error))")
                return
            }
        }

        guard session == self.session, states[area.id]?.shown == candidate.key else { return }
        states[area.id]?.showingLoading = false
        let origin = missing.isEmpty ? "paket" : fromPack > 0 ? "paket+motor" : "motor"
        sendCandidate(candidate, area: area, prepared: prepared, translated: translated,
                      anchor: anchor, loading: false, onlyTranslated: false, logOrigin: origin)
    }

    private func sendCandidate(_ candidate: Candidate, area: ExtraArea, prepared: [IconText.Protected],
                               translated: [String?], anchor: TextBox, loading: Bool,
                               onlyTranslated: Bool, logOrigin: String? = nil) {
        var slots: [IconSlot] = []
        var text: [String] = []
        for (index, source) in candidate.paragraphs.enumerated() {
            let raw = index < translated.count ? translated[index] : nil
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if onlyTranslated, trimmed.isEmpty {
                text.append("")
            } else {
                text.append(trimmed.isEmpty ? IconText.indexed(source, offset: slots.count)
                            : IconText.restore(trimmed, names: prepared[index].names, offset: slots.count))
            }
            if let all = candidate.icons, index < all.count { slots += all[index] }
        }
        // Çevirisi aslıyla aynı (ad, sayı, zaten hedef dilde) ya da kademeli modda henüz boş: atla.
        let similar = zip(candidate.paragraphs, text).map { source, out in
            if onlyTranslated, out.isEmpty { return true }
            return TextMatch.isSimilar(TextMatch.normalize(IconText.plain(source)),
                                       TextMatch.normalize(IconText.plain(out)), threshold: 0.90)
        }
        if similar.allSatisfy({ $0 }) {
            if !loading {
                server.sendRegion(id: area.id, text: "", box: nil, lineHeight: nil)
                states[area.id]?.renderedKey = candidate.key
                states[area.id]?.renderedText = ""
                states[area.id]?.renderedIcons = nil
                states[area.id]?.renderedBox = nil
                states[area.id]?.renderedLineHeight = nil
                states[area.id]?.renderedLayout = nil
                states[area.id]?.renderedBlocks = nil
            }
            return
        }
        if let logOrigin {
            onLog?("ek alan \(area.name): \(SubtitleLog.excerpt(IconText.plain(candidate.paragraphs.joined(separator: " ")))) → \(logOrigin)")
        }
        let nonEmpty = text.filter { !$0.isEmpty }
        let rendered = IconText.render(nonEmpty.joined(separator: "\n"), slots: slots)
        let icons = rendered.icons.isEmpty ? nil : rendered.icons
        let blocks = candidate.blocks.map { Self.renderBlocks(candidate, layout: $0, text: text, similar: similar, slots: slots) }
        let opts = BubbleOptions(theme: area.bubbleTheme, scale: area.bubbleScale, layout: candidate.phoneLayout,
                                 loading: loading, phoneHeader: candidate.phoneHeader)
        server.sendRegion(id: area.id, text: rendered.text, box: candidate.box, lineHeight: candidate.lineHeight, icons: icons,
                          blocks: blocks?.map(\.item), presentation: area.presentation, anchor: anchor, options: opts)
        if !loading {
            states[area.id]?.shownAt = now()
            states[area.id]?.holdUntil = nil
            states[area.id]?.holdTask?.cancel()
            states[area.id]?.holdTask = nil
            states[area.id]?.renderedKey = candidate.key
            states[area.id]?.renderedText = rendered.text
            states[area.id]?.renderedIcons = icons
            states[area.id]?.renderedBox = candidate.box
            states[area.id]?.renderedLineHeight = candidate.lineHeight
            states[area.id]?.renderedLayout = candidate.blocks
            states[area.id]?.renderedBlocks = blocks
            states[area.id]?.lastPhoneLayout = candidate.phoneLayout
            states[area.id]?.lastPhoneHeader = candidate.phoneHeader
            if area.onlyWhenVisible, let renderedBlocks = blocks {
                rememberThread(renderedBlocks.map(\.item), areaId: area.id)
            }
        }
    }

    private func resolveImmediate(_ paragraphs: [String], prepared: [IconText.Protected], senders: [String?]?) -> [String?] {
        var result: [String?] = Array(repeating: nil, count: paragraphs.count)
        for index in paragraphs.indices {
            let plain = IconText.plain(paragraphs[index])
            // 1) Oyun paketi: önce gövdeyi, sonra "Gönderen Gövde" ve "Gönderen: Gövde" biçimlerini dene.
            if let hit = packLookup?(plain)?.text {
                result[index] = hit
                continue
            }
            if let sender = senders?[index], !sender.isEmpty {
                if let hit = packLookup?("\(sender) \(plain)")?.text ?? packLookup?("\(sender): \(plain)")?.text {
                    result[index] = hit
                    continue
                }
            }
            // 2) Zaten Türkçe olan parça çevrilmez.
            if skipsTurkish, TurkishText.isSure(paragraphs[index]) {
                result[index] = paragraphs[index]
                continue
            }
            // 3) Oturum içi önbellek.
            if let cached = lineCache[prepared[index].text] {
                result[index] = cached
            }
        }
        return result
    }

    private static func plainKey(_ key: String) -> String {
        if let pipe = key.firstIndex(of: "|") { return String(key[..<pipe]) }
        return key
    }

    private static func isSmallJitter(_ a: TextBox?, _ b: TextBox?, tolerance: Double) -> Bool {
        guard let a, let b else { return a == b }
        return abs(a.left - b.left) <= tolerance
            && abs(a.right - b.right) <= tolerance
            && abs(a.top - b.top) <= tolerance
            && abs(a.bottom - b.bottom) <= tolerance
    }

    /// Her grubun çevirisi kendi yeriyle. Çevirisi aslıyla aynı grup (ad, sayı) atlanır; İngilizcesi görünür kalır.
    /// `text` simge imlerini bütün alanın sırasıyla taşır; `slots` o sıradaki simgeler.
    static func renderBlocks(_ candidate: Candidate, layout: [Block], text: [String], similar: [Bool],
                             slots: [IconSlot]) -> [(group: Int, item: ScreenTranslation.Item)] {
        var result: [(group: Int, item: ScreenTranslation.Item)] = []
        for (index, block) in layout.enumerated() {
            let range = block.start..<(block.start + block.count)
            if range.allSatisfy({ similar[$0] }) { continue }
            let rendered = IconText.render(range.map { text[$0] }.joined(separator: "\n"), slots: slots)
            let source = range.map { IconText.plain(candidate.paragraphs[$0]) }.joined(separator: "\n")
            result.append((index, ScreenTranslation.Item(source: source, translation: rendered.text, box: block.box,
                                                          lineHeight: block.lineHeight,
                                                          icons: rendered.icons.isEmpty ? nil : rendered.icons,
                                                          sender: block.sender,
                                                          senderColor: block.senderColor,
                                                          msgId: block.msgId,
                                                          side: block.side,
                                                          timestamp: block.timestamp,
                                                          dateLabel: block.dateLabel)))
        }
        return result
    }

    private static func mergeHeader(new: PhoneContent.Header?, previous: PhoneContent.Header?) -> PhoneContent.Header? {
        guard let previous else { return new }
        guard let new else { return previous }
        let merged = PhoneContent.Header(
            title: new.title ?? previous.title,
            subtitle: new.subtitle ?? previous.subtitle,
            clock: new.clock ?? previous.clock,
            accentColor: new.accentColor ?? previous.accentColor
        )
        return merged.isEmpty ? nil : merged
    }

    /// Kaydırma sırasında aynı mesaj 1-2 karakter OCR farkıyla tekrar okunursa mevcut `msgId` ve çevirisini korur.
    private static func stabilizeScrollCandidate(_ candidate: Candidate, memory: [ThreadMemory]) -> (candidate: Candidate, translations: [Int: String]) {
        guard !memory.isEmpty, var blocks = candidate.blocks else { return (candidate, [:]) }
        var hits: [Int: String] = [:]
        for idx in blocks.indices {
            let pIdx = blocks[idx].start
            guard pIdx < candidate.paragraphs.count else { continue }
            let norm = TextMatch.normalize(IconText.plain(candidate.paragraphs[pIdx]))
            guard norm.count >= 4 else { continue }
            let side = blocks[idx].side ?? .incoming
            let sender = blocks[idx].sender
            if let match = memory.last(where: { item in
                item.side == side
                    && (item.sender == sender || item.sender == nil || sender == nil)
                    && (item.normSource == norm || TextMatch.isSimilar(item.normSource, norm, threshold: 0.88))
            }) {
                blocks[idx].msgId = match.msgId
                hits[pIdx] = match.translation
            }
        }
        var updated = candidate
        updated.blocks = blocks
        return (updated, hits)
    }

    private func rememberThread(_ items: [ScreenTranslation.Item], areaId: String) {
        guard var list = states[areaId]?.recentThread else { return }
        for item in items {
            let norm = TextMatch.normalize(item.source)
            guard !norm.isEmpty, let msgId = item.msgId else { continue }
            let entry = ThreadMemory(msgId: msgId, side: item.side ?? .incoming,
                                     sender: item.sender, normSource: norm, translation: item.translation)
            if let existing = list.firstIndex(where: { $0.msgId == msgId }) {
                list[existing] = entry
            } else {
                list.append(entry)
            }
        }
        if list.count > 40 { list.removeFirst(list.count - 40) }
        states[areaId]?.recentThread = list
    }

    private func rememberTranslation(_ source: String, _ translation: String) {
        let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if lineCache[source] == nil {
            lineCacheOrder.append(source)
            if lineCacheOrder.count > Self.maxCachedLines {
                let oldest = lineCacheOrder.removeFirst()
                lineCache.removeValue(forKey: oldest)
            }
        }
        lineCache[source] = translation
    }

    private func loadPersistentCache() {
        guard let cacheFile,
              let data = try? Data(contentsOf: cacheFile),
              let saved = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        for (k, v) in saved.prefix(Self.maxCachedLines) {
            lineCache[k] = v
            lineCacheOrder.append(k)
        }
    }

    private func savePersistentCache() {
        guard let cacheFile else { return }
        let snapshot = lineCache
        Task.detached(priority: .background) {
            let dir = cacheFile.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: cacheFile, options: .atomic)
            }
        }
    }

    private func sequential(_ texts: [String]) async throws -> [String] {
        var result: [String] = []
        for text in texts { result.append(try await translator.translate(text)) }
        return result
    }

    /// Çeviri durdu ya da hat yeniden kuruldu: süren tur bırakılır, TV'deki ek alan kutuları kalkar.
    /// Kalıcı telefon önbelleği (`cacheFile` varsa) korunur.
    public func reset() {
        session += 1
        running?.cancel()
        running = nil
        lastPass = nil
        if cacheFile == nil {
            lineCache.removeAll()
            lineCacheOrder.removeAll()
        }
        for state in states.values { state.holdTask?.cancel() }
        let anyShown = states.values.contains { !$0.shown.isEmpty || $0.showingLoading }
        states.removeAll()
        if anyShown { server.clearRegions() }
    }

    private func clearVisibleState(_ state: inout State, id: String, name: String) {
        let hadAnything = !state.shown.isEmpty || state.showingLoading || state.holdUntil != nil
        state.holdTask?.cancel()
        state.holdTask = nil
        state.holdUntil = nil
        state.shownAt = nil
        state.lowConfidenceRetries = 0
        state.shown = ""
        state.showingLoading = false
        state.renderedKey = nil
        state.renderedText = ""
        state.renderedIcons = nil
        state.renderedBox = nil
        state.renderedLineHeight = nil
        state.renderedLayout = nil
        state.renderedBlocks = nil
        state.lastPhoneHeader = nil
        state.recentThread.removeAll()
        guard hadAnything else { return }
        server.sendRegion(id: id, text: "", box: nil, lineHeight: nil)
        onLog?("ek alan \(name): panel kapandı")
    }

    private func expireHold(id: String, name: String) {
        guard var state = states[id], state.panelVisible == false, state.holdUntil != nil else { return }
        clearVisibleState(&state, id: id, name: name)
        states[id] = state
    }

    /// Metnin uzunluğuna göre en az okuma süresi: kısa bildirim en az `baseMs`, uzun mesaj 7.5 saniyeye kadar.
    static func readingHoldMs(for text: String, baseMs: Int) -> Int {
        guard baseMs > 0 else { return 0 }
        return min(7500, max(baseMs, 2400 + text.count * 45))
    }
}
