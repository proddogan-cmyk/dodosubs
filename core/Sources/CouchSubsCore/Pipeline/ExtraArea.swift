// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Ek alanın TV ve bilgisayar ekranında nasıl gösterileceği.
public enum RegionPresentation: String, Codable, Equatable, Sendable {
    /// Varsayılan: yazının tam üstünde koyu kutu (görev yazısı, bildirim).
    case overlay
    /// Telefon/panel için: telefonun hemen yanında buzlu cam konuşma balonu; telefon ekranı kapanmaz,
    /// ok ucu ilgili mesaja işaret eder.
    case sideBubble
}

/// Telefon yan balonlarının görsel teması (TV ve Mac ekranında anında uygulanır).
public enum BubbleTheme: String, Codable, CaseIterable, Equatable, Sendable {
    /// Füme cam + buz mavisi yansıma (Apple VisionOS / macOS tarzı).
    case appleGlass
    /// Gece moru cam + Miami turkuaz/pembe neon kenar (GTA 6 özel).
    case viceNeon
    /// Saf koyu OLED mat karbon + ince gümüş çerçeve.
    case stealthDark
}

/// Yan balonun TV'ye iletilen görsel seçenekleri.
public struct BubbleOptions: Equatable, Sendable {
    public var theme: BubbleTheme
    public var scale: Double
    public var layout: PhoneContent.Layout?
    public var loading: Bool
    /// Bildirim/telefon kapandıktan sonra okuma süresi boyunca ekranda tutuluyorsa kalan süre (ms); TV ince geri sayım
    /// çubuğu gösterir.
    public var holdMs: Int?
    /// İkiz telefon başlık bilgileri (kişi/grup adı, üye sayısı / durum, oyun içi saat).
    public var phoneHeader: PhoneContent.Header?

    public init(theme: BubbleTheme = .appleGlass, scale: Double = 1.0,
                layout: PhoneContent.Layout? = nil, loading: Bool = false, holdMs: Int? = nil,
                phoneHeader: PhoneContent.Header? = nil) {
        self.theme = theme
        self.scale = min(1.30, max(0.85, scale))
        self.layout = layout
        self.loading = loading
        self.holdMs = holdMs
        self.phoneHeader = phoneHeader
    }
}

/// Altyazı alanının yanında sürekli okunan ek alan (görev yazısı, telefon mesajı, bildirim). Ek alanlar ana altyazıdan
/// ayrı ve daha seyrek okunur (bkz. `RegionWatcher`); çevirileri TV'de kendi yerlerinde küçük kutuda görünür.
/// Windows'ta aynı işi ek bölgelerin "Sürekli oku" seçeneği yapar (CouchSubs.Core/RegionWatcher.cs).
public struct ExtraArea: Codable, Equatable, Identifiable, Sendable {
    /// En çok bu kadar ek alan tanımlanır (her biri saniyede bir okunur).
    public static let maxCount = 3
    /// Bir ek alan için kaydedilebilecek en çok çerçeve görünümü (farklı karakter / telefon temaları için).
    public static let maxTemplates = 3

    /// TV'deki kutunun kimliği; değişmez.
    public var id: String
    /// Kullanıcının verdiği ad ("Görev", "Telefon").
    public var name: String
    public var region: CropRegion
    /// Kapalı alan okunmaz, ayarı kalır.
    public var enabled: Bool
    /// Sadece telefon veya açılır panel ekranda görünürken okunur; kapandığında OCR durur ve TV'deki kutu temizlenir.
    public var onlyWhenVisible: Bool
    /// Kullanıcının "Telefonu tanıt" ile kaydettiği dış çerçeve imzaları (en çok `maxTemplates`); boşsa otomatik
    /// dikdörtgen algılama kullanılır.
    public var panelTemplates: [PanelTemplate]
    /// Çerçeve benzerlik eşiği (0.25–0.70, varsayılan 0.42).
    public var panelThreshold: Double
    /// Çerçeve tanıtıldığında dış kasayı ve üst durum çubuğunu hariç tutarak sadece iç ekranı OCR'a verir.
    public var cropInnerScreen: Bool
    /// Çevirinin ekranda gösterim biçimi (üstünde koyu kutu mu, yanında buzlu cam balon mu).
    public var presentation: RegionPresentation
    /// Yan balon görsel teması (Apple Cam / Vice Neon / Sade OLED).
    public var bubbleTheme: BubbleTheme
    /// Yan balon yazı ölçeği (0.85–1.30, varsayılan 1.0).
    public var bubbleScale: Double

    /// Eski tekil erişim için kolaylık (ilk şablon).
    public var panelTemplate: PanelTemplate? {
        get { panelTemplates.first }
        set { panelTemplates = newValue.map { [$0] } ?? [] }
    }

    /// OCR'ın çalıştırılacağı bölge (çerçeve algılaması her zaman tam `region` üstünde yapılır).
    public var ocrRegion: CropRegion {
        if onlyWhenVisible, cropInnerScreen, !panelTemplates.isEmpty {
            return PanelPresence.innerScreenRegion(of: region)
        }
        return region
    }

    public init(id: String = UUID().uuidString, name: String, region: CropRegion, enabled: Bool = true,
                onlyWhenVisible: Bool = false, panelTemplates: [PanelTemplate] = [],
                panelThreshold: Double = PanelPresence.defaultThreshold, cropInnerScreen: Bool = true,
                presentation: RegionPresentation? = nil, bubbleTheme: BubbleTheme = .appleGlass,
                bubbleScale: Double = 1.0) {
        self.id = id
        self.name = name
        self.region = region
        self.enabled = enabled
        self.onlyWhenVisible = onlyWhenVisible
        self.panelTemplates = Array(panelTemplates.prefix(Self.maxTemplates))
        self.panelThreshold = PanelPresence.clampedThreshold(panelThreshold)
        self.cropInnerScreen = cropInnerScreen
        self.presentation = presentation ?? (onlyWhenVisible ? .sideBubble : .overlay)
        self.bubbleTheme = bubbleTheme
        self.bubbleScale = min(1.30, max(0.85, bubbleScale))
    }

    public init(id: String = UUID().uuidString, name: String, region: CropRegion, enabled: Bool = true,
                onlyWhenVisible: Bool, panelTemplate: PanelTemplate?) {
        self.init(id: id, name: name, region: region, enabled: enabled, onlyWhenVisible: onlyWhenVisible,
                  panelTemplates: panelTemplate.map { [$0] } ?? [])
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, region, enabled, onlyWhenVisible, panelTemplates, panelTemplate, panelThreshold,
             cropInnerScreen, presentation, bubbleTheme, bubbleScale
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        region = try values.decodeIfPresent(CropRegion.self, forKey: .region) ?? ExtraAreaPreset.quest.region
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        onlyWhenVisible = try values.decodeIfPresent(Bool.self, forKey: .onlyWhenVisible) ?? false
        if let list = try values.decodeIfPresent([PanelTemplate].self, forKey: .panelTemplates) {
            panelTemplates = Array(list.prefix(Self.maxTemplates))
        } else if let legacy = try values.decodeIfPresent(PanelTemplate.self, forKey: .panelTemplate) {
            panelTemplates = [legacy]
        } else {
            panelTemplates = []
        }
        panelThreshold = PanelPresence.clampedThreshold(
            try values.decodeIfPresent(Double.self, forKey: .panelThreshold) ?? PanelPresence.defaultThreshold
        )
        cropInnerScreen = try values.decodeIfPresent(Bool.self, forKey: .cropInnerScreen) ?? true
        presentation = try values.decodeIfPresent(RegionPresentation.self, forKey: .presentation)
            ?? (onlyWhenVisible ? .sideBubble : .overlay)
        bubbleTheme = try values.decodeIfPresent(BubbleTheme.self, forKey: .bubbleTheme) ?? .appleGlass
        bubbleScale = min(1.30, max(0.85, try values.decodeIfPresent(Double.self, forKey: .bubbleScale) ?? 1.0))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(region, forKey: .region)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(onlyWhenVisible, forKey: .onlyWhenVisible)
        try container.encode(panelTemplates, forKey: .panelTemplates)
        try container.encode(panelThreshold, forKey: .panelThreshold)
        try container.encode(cropInnerScreen, forKey: .cropInnerScreen)
        try container.encode(presentation, forKey: .presentation)
        try container.encode(bubbleTheme, forKey: .bubbleTheme)
        try container.encode(bubbleScale, forKey: .bubbleScale)
    }
}

/// Ek alanın hazır seçimleri: oyunların çoğu bu yazıları ekranın köşelerinde gösterir.
public enum ExtraAreaPreset: String, CaseIterable, Sendable {
    /// Sağ üstteki görev yazısı.
    case quest
    /// Sol alttaki bildirim (eşya alındı, görev güncellendi).
    case notification
    /// Sağ alttaki telefon mesajı ya da e-posta.
    case phone

    public var region: CropRegion {
        switch self {
        case .quest: CropRegion(top: 0.03, bottom: 0.30, left: 0.66, right: 0.98)
        case .notification: CropRegion(top: 0.58, bottom: 0.88, left: 0.02, right: 0.30)
        case .phone: CropRegion(top: 0.50, bottom: 0.95, left: 0.72, right: 0.98)
        }
    }

    /// Bölge bir hazır seçimle aynıysa o.
    public static func matching(_ region: CropRegion) -> ExtraAreaPreset? {
        allCases.first { $0.region.isClose(to: region) }
    }
}

extension UserSettings {
    /// Okunacak ek alanlar (açık olanlar, en çok `ExtraArea.maxCount`). Altyazı alanı Tam ekranken hiçbiri okunmaz:
    /// ekranın tamamı zaten okunuyor, ek alanlar aynı yazıyı ikinci kez çevirirdi. Alanların açık/kapalı ayarı
    /// değişmez; başka bir alan seçilince eskisi gibi okunurlar (Windows: UserSettings.WatchedAreas, Android: watched).
    public var activeExtraAreas: [ExtraArea] {
        guard !extraAreasPausedByFullScreen else { return [] }
        return Array(extraAreas.filter(\.enabled).prefix(ExtraArea.maxCount))
    }

    /// Altyazı alanı Tam ekran: ek alanlar okunmuyor (ayarları korunur).
    public var extraAreasPausedByFullScreen: Bool { areaPreset == .full }

    /// Ek alan eklenebilir mi.
    public var canAddExtraArea: Bool { extraAreas.count < ExtraArea.maxCount }

    /// Hazır seçimle yeni ek alan ekler; sınır dolduysa bir şey yapmaz. Eklenen alanın kimliğini döner.
    @discardableResult
    public mutating func addExtraArea(_ preset: ExtraAreaPreset, name: String) -> String? {
        guard canAddExtraArea else { return nil }
        let area = ExtraArea(name: name, region: preset.region, onlyWhenVisible: preset == .phone)
        extraAreas.append(area)
        return area.id
    }

    public mutating func removeExtraArea(id: String) {
        extraAreas.removeAll { $0.id == id }
    }

    /// Kimliği verilen ek alanı değiştirir (yoksa bir şey yapmaz).
    public mutating func updateExtraArea(id: String, _ change: (inout ExtraArea) -> Void) {
        guard let index = extraAreas.firstIndex(where: { $0.id == id }) else { return }
        change(&extraAreas[index])
    }
}
