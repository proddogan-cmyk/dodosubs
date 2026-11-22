// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import Combine
import SwiftUI

/// Bilgisayar ekranındaki altyazı penceresi: kenarsız, her pencerenin (tam ekran uygulamalar dahil) üstünde, saydam
/// zeminli bir panel. Odağı almaz; "Tıklamalar geçsin" açıkken fare alttaki pencereye (oyun, PS Remote Play) gider.
/// Satırlar TV uygulamasıyla aynı yığından gelir (bkz. AppModel+ComputerScreen.swift). Yeri, genişliği ve ekranı
/// macOS'un pencere kaydıyla hatırlanır.
@MainActor
final class SubtitleOverlayController {
    private weak var model: AppModel?
    private var panel: OverlayPanel?
    private let geometry = OverlayGeometry()
    private var moveStart: (mouse: NSPoint, frame: NSRect)?
    private var screenObserver: NSObjectProtocol?
    private var modelChanges: AnyCancellable?
    /// Pencereyi etkileyen son durum; model her değiştiğinde (ör. yeni satır) pencere boşuna yeniden ölçülmesin.
    private var shown: Shown?

    private struct Shown: Equatable {
        let visible: Bool
        let ignoresMouse: Bool
        let adjusting: Bool
        let fontSize: Int
    }

    static let autosaveName = "CouchSubsSubtitleWindow"
    static let minWidth: CGFloat = 320

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        update()
        // Modeldeki görünürlük, tıklama ve yazı boyu değişince pencere güncellenir. objectWillChange değişiklikten önce
        // gelir; güncelleme bir sonraki turda yeni değerlerle yapılır.
        modelChanges = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
        }
    }

    private func update() {
        guard let model else { return }
        let visible = model.overlayVisible
        let ignoresMouse = model.overlayIgnoresMouse
        let fontSize = model.settings.style.fontSize
        let state = Shown(visible: visible, ignoresMouse: ignoresMouse, adjusting: model.overlayAdjusting, fontSize: fontSize)
        guard state != shown else { return }
        shown = state
        guard visible else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel(model)
        panel.ignoresMouseEvents = ignoresMouse
        panel.adjusting = model.overlayAdjusting
        fit(panel, fontSize: fontSize)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel(_ model: AppModel) -> OverlayPanel {
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        // Tüm masaüstlerinde ve tam ekran uygulamaların (PS Remote Play, oyun) üstünde görünür.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        let content = SubtitleOverlayView(geometry: geometry, actions: OverlayActions(
            move: { [weak self] in self?.move() },
            resize: { [weak self] edge in self?.resize(edge) },
            endMove: { [weak self] in self?.moveStart = nil }))
            .environmentObject(model)
        let host = FirstMouseHostingView(rootView: content)
        // Pencerenin boyunu içerik değil kullanıcı (ve yazı boyu) belirler.
        host.sizingOptions = []
        panel.contentView = host
        if !panel.setFrameUsingName(Self.autosaveName) || !Self.isOnScreen(panel.frame) {
            panel.setFrame(Self.defaultFrame(), display: false)
        }
        panel.setFrameAutosaveName(Self.autosaveName)
        screenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: panel,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let model = self.model, let panel = self.panel else { return }
                self.fit(panel, fontSize: model.settings.style.fontSize)
            }
        }
        self.panel = panel
        return panel
    }

    /// Yazı boyu TV'deki gibi 1080 satırlık ekrana göredir; pencerenin bulunduğu ekranın yüksekliğine ölçeklenir.
    /// Pencere en çok üç satıra (ve satırların kaymasına) yetecek kadar yüksektir; alt kenarı sabit kalır.
    private func fit(_ panel: NSPanel, fontSize: Int) {
        let screen = panel.screen ?? NSScreen.main
        let scale = (screen?.frame.height ?? 1080) / 1080
        if geometry.scale != scale { geometry.scale = scale }
        let font = CGFloat(fontSize) * scale
        let height = (font * 8.1 + 140 * scale).rounded()
        var frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    /// Sürüklemenin başındaki fare yeri ve pencere çerçevesi.
    private func dragStart() -> (mouse: NSPoint, frame: NSRect)? {
        guard let panel else { return nil }
        if moveStart == nil { moveStart = (NSEvent.mouseLocation, panel.frame) }
        return moveStart
    }

    /// Fare imlecinin ekrandaki yeriyle taşınır; ekranlar arasında da çalışır.
    private func move() {
        guard let panel, let start = dragStart() else { return }
        let mouse = NSEvent.mouseLocation
        var frame = start.frame
        frame.origin.x += mouse.x - start.mouse.x
        frame.origin.y += mouse.y - start.mouse.y
        panel.setFrame(frame, display: true)
    }

    /// Kenardan genişletme: ortası yerinde kalır, iki yana eşit büyür.
    private func resize(_ edge: HorizontalEdge) {
        guard let panel, let start = dragStart() else { return }
        let delta = NSEvent.mouseLocation.x - start.mouse.x
        let grow = edge == .trailing ? delta : -delta
        let screenWidth = panel.screen?.frame.width ?? start.frame.width
        let width = min(screenWidth, max(Self.minWidth, start.frame.width + 2 * grow))
        var frame = start.frame
        frame.origin.x = start.frame.midX - width / 2
        frame.size.width = width
        panel.setFrame(frame, display: true)
    }

    /// İlk açılışta ana ekranın altında, ortada, ekranın %70'i genişliğinde.
    private static func defaultFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = (screen.width * 0.7).rounded()
        return NSRect(x: screen.midX - width / 2, y: screen.minY + screen.height * 0.04, width: width, height: 400)
    }

    /// Kayıtlı yer artık bağlı olmayan bir ekrandaysa pencere ana ekrana döner.
    private static func isOnScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(frame) }
    }
}

/// Yazı ölçeği (pencerenin bulunduğu ekrana göre).
@MainActor
final class OverlayGeometry: ObservableObject {
    @Published var scale: CGFloat = 1
}

struct OverlayActions {
    let move: () -> Void
    let resize: (HorizontalEdge) -> Void
    let endMove: () -> Void
}

/// Odağı yalnız yeri ayarlanırken alabilen panel; oyun ya da PS Remote Play klavyeyi kaybetmez.
final class OverlayPanel: NSPanel {
    var adjusting = false

    override var canBecomeKey: Bool { adjusting }
    override var canBecomeMain: Bool { false }
}

/// Öndeki uygulama değişmeden ilk tıklama da (taşıma, "Bitti") çalışsın.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Pencerenin içeriği: TV'deki altyazı kutusunun aynısı (yazı boyu, renk, zemin, soluk üst satırlar).
struct SubtitleOverlayView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var geometry: OverlayGeometry
    let actions: OverlayActions

    private var scale: CGFloat { geometry.scale }

    var body: some View {
        let adjusting = model.overlayAdjusting
        let lines = model.overlayLines
        ZStack(alignment: .bottom) {
            if adjusting {
                RoundedRectangle(cornerRadius: Theme.radius("card"))
                    .fill(Color.black.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius("card"))
                        .strokeBorder(Color.csAccent, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
                    .gesture(moveGesture)
                adjustBar
                resizeHandles
            }
            VStack(spacing: 14 * scale) {
                ForEach(model.overlayRegions) { regionBox($0) }
                Spacer(minLength: 0)
                if lines.isEmpty, adjusting {
                    line(SubtitleStack.Line(id: 0, text: String(localized: "Subtitles appear here."), role: .current,
                                            paragraphs: false, fading: false))
                }
                ForEach(lines) { line($0) }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: lines)
            .padding(.horizontal, model.settings.style.backgroundShape == .band ? 0 : 24 * scale)
            .padding(.bottom, 8 * scale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { _ in actions.move() }
            .onEnded { _ in actions.endMove() }
    }

    private func resizeGesture(_ edge: HorizontalEdge) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { _ in actions.resize(edge) }
            .onEnded { _ in actions.endMove() }
    }

    private var adjustBar: some View {
        VStack {
            HStack(spacing: Theme.space("m")) {
                Text("Drag to move, drag the edges to resize.")
                    .font(.csCallout.weight(.semibold))
                    .foregroundStyle(.white)
                Button("Done") { model.overlayAdjusting = false }
                    .buttonStyle(.primary)
            }
            .padding(Theme.space("m"))
            Spacer()
        }
    }

    private var resizeHandles: some View {
        HStack {
            handle(.leading)
            Spacer()
            handle(.trailing)
        }
    }

    private func handle(_ edge: HorizontalEdge) -> some View {
        Capsule()
            .fill(Color.csAccent)
            .frame(width: 6, height: 48)
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(resizeGesture(edge))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    private func line(_ line: SubtitleStack.Line) -> some View {
        let style = model.settings.style
        let current = line.role == .current
        // Uzun çeviri en çok 3 satıra dengeli bölünür; 3 satıra sığmazsa yazı biraz küçülür (bkz. SubtitleWrap).
        let wrapped = line.wrapped
        let roleScale: CGFloat = switch line.role {
        case .current: 1
        case .previous: 0.80
        case .older: 0.74
        }
        let size = CGFloat(style.fontSize) * scale * roleScale * CGFloat(wrapped.scale)
        let alpha = Double(max(0, min(100, style.background))) / 100 * (current ? 1 : 0.83)
        let opacity: Double = switch line.role {
        case .current: 1
        case .previous: 0.78
        case .older: 0.56
        }
        // Derleyici uzun zincirde tür çıkarımında takılmasın diye değerler önce hesaplanır (CI'daki Xcode).
        let weight: Font.Weight = style.bold ? .bold : .semibold
        let twoSpeaker = !line.paragraphs && Self.isTwoSpeakerDialogue(wrapped.text)
        let alignment: TextAlignment = (line.paragraphs || twoSpeaker) ? .leading : .center
        let thinBg = alpha < 0.5
        let vertical: CGFloat = (current ? 10 : 6) * scale
        let horizontal: CGFloat = (current ? 26 : 20) * scale
        // Bant: kutu pencerenin tüm genişliğini kaplar, oyundaki İngilizce yazıyı yan yana da gizler.
        let band = style.backgroundShape == .band
        let corner: CGFloat = band ? 0 : 12 * scale
        let shown: Double = line.fading ? 0 : opacity
        let displayText = line.paragraphs ? wrapped.text : Self.polishTypography(wrapped.text)
        let attributed = Self.richSubtitle(displayText, size: size, weight: weight, baseColor: Self.color(style.textColor))
        let text = Text(attributed)
            .tracking(size * 0.014)
        return text
            .multilineTextAlignment(alignment)
            .lineSpacing(size * 0.32)
            .shadow(color: .black.opacity(thinBg ? 0.96 : 0.9), radius: (thinBg ? 1.5 : 2) * scale, x: 0, y: 1.5 * scale)
            .shadow(color: .black.opacity(thinBg ? 0.85 : 0.45), radius: (thinBg ? 9 : 6) * scale, x: 0, y: (thinBg ? 3 : 2) * scale)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, vertical)
            .padding(.horizontal, horizontal)
            .frame(maxWidth: band ? .infinity : nil)
            .background(Color(red: 12 / 255, green: 14 / 255, blue: 18 / 255).opacity(alpha), in: RoundedRectangle(cornerRadius: corner))
            .shadow(color: (!thinBg && !band) ? .black.opacity(0.38) : .clear, radius: 14 * scale, x: 0, y: 5 * scale)
            .opacity(shown)
            .offset(y: line.fading ? -14 * scale : 0)
            .scaleEffect(line.fading ? 0.96 : 1, anchor: .bottom)
            .animation(.easeOut(duration: SubtitleStack.previousFade), value: line.fading)
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            ))
            .contentShape(Rectangle())
            .gesture(moveGesture)
    }

    /// Ek alanın çevirisi: normal alanlarda koyu kutu, telefon yan balonunda gerçekçi buzlu cam İkiz Telefon.
    private func regionBox(_ region: OverlayRegion) -> some View {
        let style = model.settings.style
        let size = max(12, CGFloat(style.fontSize) * scale * 0.50 * CGFloat(region.options.scale))
        let alignment: Alignment = switch region.side {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        let isBubble = region.presentation == .sideBubble
        return Group {
            if isBubble {
                twinPhoneMirror(region, size: size)
            } else {
                Text(verbatim: region.text)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(Self.color(style.textColor))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6 * scale)
                    .padding(.horizontal, 14 * scale)
                    .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8 * scale))
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .contentShape(Rectangle())
        .gesture(moveGesture)
    }

    private func twinPhoneMirror(_ region: OverlayRegion, size: CGFloat) -> some View {
        let borderTint: Color = switch region.theme {
        case .appleGlass: Color.white.opacity(0.24)
        case .viceNeon: Color.pink.opacity(0.60)
        case .stealthDark: Color.white.opacity(0.14)
        }
        let glassTint: Color = switch region.theme {
        case .appleGlass: Color(red: 0.07, green: 0.10, blue: 0.16).opacity(0.72)
        case .viceNeon: Color(red: 0.13, green: 0.05, blue: 0.22).opacity(0.76)
        case .stealthDark: Color(red: 0.04, green: 0.05, blue: 0.07).opacity(0.88)
        }
        let outgoingTint: Color = switch region.theme {
        case .appleGlass: Color(red: 0.05, green: 0.48, blue: 0.96).opacity(0.88)
        case .viceNeon: Color(red: 0.85, green: 0.26, blue: 0.62).opacity(0.86)
        case .stealthDark: Color(red: 0.06, green: 0.46, blue: 0.42).opacity(0.90)
        }
        let header = region.options.phoneHeader
        let title = header?.title ?? (region.options.layout == .card ? "Telefon" : "Mesajlar")
        let subtitle = header?.subtitle ?? (region.options.layout == .chat ? "Canlı çeviri" : nil)
        let blocks = region.blocks ?? []

        return VStack(alignment: .leading, spacing: 0) {
            // Üst durum çubuğu (saat + TR) ve sohbet başlığı.
            VStack(alignment: .leading, spacing: 5 * scale) {
                if let clock = header?.clock, !clock.isEmpty {
                    HStack {
                        Text(clock)
                            .font(.system(size: size * 0.62, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Text("TR")
                            .font(.system(size: size * 0.56, weight: .heavy))
                            .padding(.horizontal, 6 * scale)
                            .padding(.vertical, 1 * scale)
                            .background(Color.white.opacity(0.14), in: Capsule())
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                HStack(spacing: 8 * scale) {
                    Circle()
                        .fill(Self.hexColor(header?.accentColor) ?? Color.cyan)
                        .frame(width: size * 1.35, height: size * 1.35)
                        .overlay(Text(String(title.prefix(1)).uppercased())
                            .font(.system(size: size * 0.72, weight: .heavy))
                            .foregroundStyle(Color(red: 0.05, green: 0.07, blue: 0.14)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: size * 0.86, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: size * 0.64, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.68))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 9 * scale)
            .background(Color.white.opacity(0.05))

            Divider().overlay(Color.white.opacity(0.12))

            VStack(alignment: .leading, spacing: 7 * scale) {
                if blocks.isEmpty {
                    Text(verbatim: region.text)
                        .font(.system(size: size, weight: .medium))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { idx, item in
                        let isOutgoing = item.side == .outgoing
                        let prev = idx > 0 ? blocks[idx - 1] : nil
                        let grouped = !isOutgoing && item.sender != nil && prev?.side != .outgoing && prev?.sender == item.sender && item.dateLabel == nil
                        if let date = item.dateLabel, !date.isEmpty, prev?.dateLabel != date {
                            HStack {
                                Spacer()
                                Text(date)
                                    .font(.system(size: size * 0.62, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .padding(.horizontal, 9 * scale)
                                    .padding(.vertical, 2 * scale)
                                    .background(Color.white.opacity(0.12), in: Capsule())
                                Spacer()
                            }
                        }
                        HStack {
                            if isOutgoing { Spacer(minLength: 28 * scale) }
                            VStack(alignment: .leading, spacing: 3 * scale) {
                                if !isOutgoing, !grouped, let sender = item.sender, !sender.isEmpty {
                                    Text(sender)
                                        .font(.system(size: size * 0.70, weight: .bold))
                                        .foregroundStyle(Self.hexColor(item.senderColor) ?? Color.cyan)
                                }
                                Text(verbatim: item.translation)
                                    .font(.system(size: size, weight: .medium))
                                    .foregroundStyle(.white)
                                    .fixedSize(horizontal: false, vertical: true)
                                if (item.timestamp != nil && !(item.timestamp?.isEmpty ?? true)) || isOutgoing {
                                    HStack(spacing: 4 * scale) {
                                        Spacer(minLength: 0)
                                        if let time = item.timestamp, !time.isEmpty {
                                            Text(time)
                                                .font(.system(size: size * 0.58, weight: .semibold))
                                                .foregroundStyle(.white.opacity(0.75))
                                        }
                                        if isOutgoing {
                                            Text("✓✓")
                                                .font(.system(size: size * 0.58, weight: .bold))
                                                .foregroundStyle(Color.cyan.opacity(0.95))
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 7 * scale)
                            .padding(.horizontal, 11 * scale)
                            .background(isOutgoing ? outgoingTint : Color.white.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 13 * scale, style: .continuous))
                            if !isOutgoing { Spacer(minLength: 24 * scale) }
                        }
                    }
                }
            }
            .padding(11 * scale)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: blocks.map { $0.msgId ?? $0.translation })
        }
        .frame(maxWidth: 360 * scale)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20 * scale, style: .continuous))
        .background(glassTint, in: RoundedRectangle(cornerRadius: 20 * scale, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20 * scale, style: .continuous)
                .strokeBorder(borderTint, lineWidth: 1.2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20 * scale, style: .continuous))
        .shadow(color: region.theme == .viceNeon ? Color.pink.opacity(0.24) : .black.opacity(0.42),
                radius: 16 * scale, x: 0, y: 8 * scale)
    }

    private static func hexColor(_ hex: String?) -> Color? {
        guard let hex, hex.hasPrefix("#"), hex.count == 7,
              let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    /// TV uygulamasındaki OLED-dostu sinema renkleri (kırık beyaz #F5F6F8, sıcak sinema sarısı #FCE26B).
    static func color(_ color: SubtitleTextColor) -> Color {
        switch color {
        case .white: Color(red: 0xF5 / 255, green: 0xF6 / 255, blue: 0xF8 / 255)
        case .yellow: Color(red: 0xFC / 255, green: 0xE2 / 255, blue: 0x6B / 255)
        }
    }

    private static let sfxTokenRegex = try! NSRegularExpression(pattern: #"(\[[^\]\n]{1,42}\]|\([^\)\n]{1,42}\)|\*[^*\n]{1,42}\*)"#)
    private static let voiceTagRegex = try! NSRegularExpression(pattern: #"(radyo|telsiz|radio|intercom|hoparlör|telefon|phone|fısıld|whisper|mırıldan|dış ses|anons|\bpa\b|\btv\b|kayıt)"#, options: [.caseInsensitive])

    private static func isTwoSpeakerDialogue(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2 else { return false }
        let dashed = lines.filter { line in
            let t = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let first = t.first, first == "-" || first == "–" || first == "—" else { return false }
            let rest = t.dropFirst()
            return rest.first == " " && rest.dropFirst().contains(where: { !$0.isWhitespace })
        }
        return dashed.count >= 2
    }

    private static func polishTypography(_ text: String) -> String {
        guard isTwoSpeakerDialogue(text) else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let s = String(line)
            if let range = s.range(of: #"^\s*-\s+"#, options: .regularExpression) {
                return "– " + s[range.upperBound...]
            }
            return s
        }.joined(separator: "\n")
    }

    /// `[Radyo]`, `(Fısıldayarak)`, `*Siren*` ve `♪ şarkı sözleri ♪` kalıplarını sinema biçiminde (italik/gümüş/altın) renklendirir.
    private static func richSubtitle(_ text: String, size: CGFloat, weight: Font.Weight, baseColor: Color) -> AttributedString {
        let baseFont = Font.system(size: size, weight: weight)
        let italicFont = Font.system(size: size, weight: weight).italic()
        let sfxFont = Font.system(size: size * 0.92, weight: weight).italic()
        let sfxColor = Color(red: 226 / 255, green: 232 / 255, blue: 240 / 255).opacity(0.86)
        let musicColor = Color(red: 0xFD / 255, green: 0xE6 / 255, blue: 0x8A / 255)

        var output = AttributedString()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (idx, rawLine) in lines.enumerated() {
            if idx > 0 { output.append(AttributedString("\n")) }
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("♪") || trimmed.hasPrefix("♫") || trimmed.hasSuffix("♪") || trimmed.hasSuffix("♫") {
                var part = AttributedString(line)
                part.font = italicFont
                part.foregroundColor = musicColor
                output.append(part)
                continue
            }
            let ns = line as NSString
            let matches = sfxTokenRegex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty {
                var part = AttributedString(line)
                part.font = baseFont
                part.foregroundColor = baseColor
                output.append(part)
                continue
            }
            var cursor = 0
            var italicRest = false
            for match in matches {
                if match.range.location > cursor {
                    let chunk = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                    var part = AttributedString(chunk)
                    part.font = italicRest ? italicFont : baseFont
                    part.foregroundColor = baseColor
                    output.append(part)
                }
                let token = ns.substring(with: match.range)
                var sfxPart = AttributedString(token)
                sfxPart.font = sfxFont
                sfxPart.foregroundColor = sfxColor
                output.append(sfxPart)
                if voiceTagRegex.firstMatch(in: token, range: NSRange(location: 0, length: (token as NSString).length)) != nil {
                    italicRest = true
                }
                cursor = match.range.location + match.range.length
            }
            if cursor < ns.length {
                let tail = ns.substring(from: cursor)
                var part = AttributedString(tail)
                part.font = italicRest ? italicFont : baseFont
                part.foregroundColor = baseColor
                output.append(part)
            }
        }
        return output
    }
}
