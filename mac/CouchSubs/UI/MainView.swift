// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import RemotePlay
import SwiftUI

/// DodoSubs Tam Ekran Liquid Glass Stüdyo Kabuğu:
/// Solda kayan buzlu cam gezinme rayı + sabit alt ulaşım (Başlat/Durdur/Test), sağda 6 entegre çalışma alanı.
/// Modal pencere karmaşası olmadan tek akıcı Apple Pro stüdyo deneyimi sunar.
struct MainView: View {
    enum StudioTab: String, CaseIterable, Identifiable {
        case studio, monitor, history, appearance, engine, hardware
        var id: Self { self }

        var title: String {
            switch self {
            case .studio: "Stüdyo"
            case .monitor: "Canlı Monitör"
            case .history: "Geçmiş"
            case .appearance: "Altyazı & TV"
            case .engine: "Çeviri & Paketler"
            case .hardware: "PS5, Ses & OBS"
            }
        }

        var symbol: String {
            switch self {
            case .studio: "sparkles.tv"
            case .monitor: "viewfinder.rectangular"
            case .history: "clock.arrow.circlepath"
            case .appearance: "textformat.size"
            case .engine: "cpu"
            case .hardware: "slider.horizontal.3"
            }
        }

        var group: String {
            switch self {
            case .studio, .monitor, .history: "CANLI"
            case .appearance, .engine: "TASARIM & MOTOR"
            case .hardware: "DONANIM & SİSTEM"
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @State private var activeTab: StudioTab = .studio
    @State private var latencySamples: [Int] = []
    @State private var showMiniMonitor = false
    @Namespace private var navSelectionNS

    /// `MainLayoutTests` uyumluluğu için korunur.
    static let controlsColumnMin: CGFloat = 340
    static let liveColumnMin: CGFloat = 320

    var body: some View {
        HStack(spacing: 0) {
            StudioNavigationRail(activeTab: $activeTab, namespace: navSelectionNS)
            ZStack {
                switch activeTab {
                case .studio:
                    StudioDashboardWorkspace(
                        activeTab: $activeTab,
                        latencySamples: latencySamples,
                        showMiniMonitor: $showMiniMonitor
                    )
                case .monitor:
                    MonitorAreasWorkspace()
                case .history:
                    HistoryWorkspaceView()
                        .padding(.horizontal, 24)
                        .padding(.top, 28)
                        .padding(.bottom, 22)
                case .appearance:
                    AppearanceTVWorkspace()
                case .engine:
                    EnginePacksWorkspace()
                case .hardware:
                    HardwareSystemWorkspace()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Menüden (⌘,) veya iç düğmelerden Ayarlar / Geçmiş istendiğinde modal yerine ilgili stüdyo sekmesine kayar.
        .onChange(of: model.showSettings) { open in
            guard open else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                activeTab = Self.tab(for: model.settingsSection)
            }
            model.showSettings = false
        }
        .onChange(of: model.showHistory) { open in
            guard open else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                activeTab = .history
            }
            model.showHistory = false
        }
        .onChange(of: model.lastMetrics) { metrics in
            guard let ms = metrics?.totalMs else { return }
            latencySamples.append(ms)
            if latencySamples.count > 24 { latencySamples.removeFirst(latencySamples.count - 24) }
        }
    }

    private static func tab(for section: SettingsSection) -> StudioTab {
        switch section {
        case .appearance: .appearance
        case .area: .monitor
        case .translation, .packs, .language: .engine
        case .dubbing, .obs, .source, .ps5, .about: .hardware
        }
    }
}

// MARK: - Sol Liquid Glass Gezinme Rayı

private struct StudioNavigationRail: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Binding var activeTab: MainView.StudioTab
    let namespace: Namespace.ID

    private let groups: [(String, [MainView.StudioTab])] = [
        ("CANLI", [.studio, .monitor, .history]),
        ("TASARIM & MOTOR", [.appearance, .engine]),
        ("DONANIM & SİSTEM", [.hardware]),
    ]

    var body: some View {
        let dark = colorScheme == .dark
        VStack(alignment: .leading, spacing: 0) {
            // macOS trafik ışıkları için temiz üst alan
            Color.clear.frame(height: 36)

            // Marka başlığı
            HStack(spacing: 10) {
                LogoView(size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "DodoSubs")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.csText)
                    HStack(spacing: 5) {
                        if model.isRunning {
                            LiveDot(color: .csSuccess)
                            Text("Canlı Yayında")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.csSuccess)
                        } else {
                            Circle().fill(Color.csSecondary.opacity(0.55)).frame(width: 6, height: 6)
                            Text("Liquid Studio")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.csSecondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)

            // Gruplu sekmeler
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups, id: \.0) { groupTitle, tabs in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: groupTitle)
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1.1)
                                .foregroundStyle(Color.csSecondary.opacity(0.75))
                                .padding(.horizontal, 12)
                                .padding(.bottom, 2)
                            ForEach(tabs) { tab in
                                RailTabButton(
                                    tab: tab,
                                    selected: activeTab == tab,
                                    badge: badgeText(for: tab),
                                    namespace: namespace
                                ) {
                                    withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                                        activeTab = tab
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 10)

            // Sabit alt stüdyo kontrol iskelesi: hangi sekmede olunursa olunsun tek tıkla Başlat / Test / Ekranı Çevir
            VStack(spacing: 8) {
                Divider().overlay(Color.csBorder.opacity(0.55))
                Button {
                    if model.demoMode {
                        model.exitDemo()
                    } else {
                        Task { model.isRunning ? model.stop() : await model.start() }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: model.demoMode ? "xmark" : (model.isRunning ? "stop.fill" : "play.fill"))
                            .font(.system(size: 13, weight: .bold))
                        Text(model.demoMode ? "Denemeden Çık" : (model.isRunning ? "Durdur" : "Çeviriyi Başlat"))
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .buttonStyle(CSButtonStyle(kind: model.isRunning || model.demoMode ? .danger : .primary, fullWidth: true, height: "buttonLarge"))
                .disabled(model.isStarting || (!model.isRunning && !model.canStart && !model.demoMode))

                HStack(spacing: 6) {
                    Button {
                        Task { await model.testSubtitle() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: model.settings.output.showsOnTV ? "tv" : "macwindow")
                                .font(.system(size: 12, weight: .semibold))
                            Text(model.openingTVAppForTest ? "Açılıyor…" : "Test")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CSButtonStyle(kind: .secondary, fullWidth: true, height: "buttonHeight"))
                    .disabled((model.settings.output.showsOnTV && !model.hasTV && !model.settings.output.showsOnComputer) || model.openingTVAppForTest)
                    .help(Text("TV'ye örnek altyazı gönder"))

                    Button { model.translateScreen() } label: {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(CSButtonStyle(kind: .secondary, height: "buttonHeight"))
                    .disabled(!model.isRunning)
                    .help(Text("Ekranı şimdi çevir (⌥⌘T)"))

                    Button { model.showAbout = true } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(CSButtonStyle(kind: .secondary, height: "buttonHeight"))
                    .help(Text("DodoSubs Hakkında"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
            .padding(.top, 4)
        }
        .frame(width: 232)
        .frame(maxHeight: .infinity)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Color.csSurface.opacity(dark ? 0.56 : 0.72))
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(dark ? 0.16 : 0.65), Color.csBorder.opacity(0.45), Color.csAccent.opacity(0.12)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 1)
        }
    }

    private func badgeText(for tab: MainView.StudioTab) -> String? {
        switch tab {
        case .history:
            return model.history.entries.isEmpty ? nil : "\(model.history.entries.count)"
        case .monitor:
            let c = model.settings.extraAreas.count
            return c > 0 ? "\(c)" : nil
        case .engine:
            return model.settings.gamePacks && !model.installedPacks.isEmpty ? "\(model.installedPacks.count)" : nil
        default:
            return nil
        }
    }
}

private struct RailTabButton: View {
    let tab: MainView.StudioTab
    let selected: Bool
    let badge: String?
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius("control"), style: .continuous)
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 14, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.csAccentText : Color.csSecondary)
                    .frame(width: 20)
                Text(verbatim: tab.title)
                    .font(.system(size: 14, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.csText : Color.csText.opacity(0.82))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let badge {
                    Text(verbatim: badge)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(selected ? Color.csAccentText : Color.csSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background((selected ? Color.csAccent.opacity(0.16) : Color.csSurface2.opacity(0.85)), in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background {
                if selected {
                    shape
                        .fill(Color.csAccentSoft.opacity(0.82))
                        .overlay(shape.strokeBorder(Color.csAccent.opacity(0.32), lineWidth: 1))
                        .matchedGeometryEffect(id: "railActivePill", in: namespace)
                } else if hovering {
                    shape.fill(Color.csSurface2.opacity(0.55))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 1. Stüdyo Kontrol Güvertesi (Bento Broadcast Deck)

private struct StudioDashboardWorkspace: View {
    @EnvironmentObject private var model: AppModel
    @Binding var activeTab: MainView.StudioTab
    let latencySamples: [Int]
    @Binding var showMiniMonitor: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Üst: Canlı Sinyal Hattı (PS5 → Motor → LG OLED TV) + Oturum Kronometresi
                SignalPipelineBanner(activeTab: $activeTab)

                // Ana Bento Izgarası: Sol %65 Sinema Sahnesi | Sağ %35 Hızlı Stüdyo Rafı
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.demoMode {
                            DemoFrameTile(preview: model.framePreview)
                        }
                        CinemaStageCard(latencySamples: latencySamples)
                        LiveDialogueFeedCard(onOpenHistory: {
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) { activeTab = .history }
                        })
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    VStack(alignment: .leading, spacing: 14) {
                        QuickStudioRackCard(activeTab: $activeTab)
                        ExtraRegionsSummaryCard(onEdit: {
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) { activeTab = .monitor }
                        })
                        if !model.demoMode {
                            CollapsiblePS5MonitorCard(preview: model.framePreview, expanded: $showMiniMonitor)
                        }
                        if model.isRunning && !model.demoMode {
                            GameSection(choice: model.gameChoice, areas: model.gameAreas)
                        }
                        MainWarnings()
                    }
                    .frame(width: 318, alignment: .topLeading)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.automatic)
    }
}

/// Canlı görsel sinyal zinciri: [PS5] ──▶ [Çeviri Motoru] ──▶ [LG OLED TV · OLED Kalkanı] + canlı kronometre.
private struct SignalPipelineBanner: View {
    @EnvironmentObject private var model: AppModel
    @Binding var activeTab: MainView.StudioTab

    var body: some View {
        HStack(spacing: 12) {
            PipelineNode(
                symbol: model.demoMode ? "play.rectangle.fill" : "gamecontroller.fill",
                title: model.demoMode ? "Demo Modu" : (model.console?.name.isEmpty == false ? model.console!.name : "PS5"),
                subtitle: model.ps5StatusText,
                tone: AppModel.ps5Tone(model.sessionState, running: model.isRunning)
            ) {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) { activeTab = .hardware }
            }

            SignalConnector(active: model.isRunning, color: .csAccent)

            PipelineNode(
                symbol: "sparkles",
                title: engineTitle,
                subtitle: packSubtitle,
                tone: model.isRunning ? .good : .idle
            ) {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) { activeTab = .engine }
            }

            SignalConnector(active: model.isRunning && (model.tvClients > 0 || model.settings.output.showsOnComputer), color: .csSuccess)

            PipelineNode(
                symbol: model.settings.output.showsOnTV ? "tv.fill" : "macwindow",
                title: destinationTitle,
                subtitle: destinationSubtitle,
                tone: destinationTone,
                shieldBadge: model.isRunning && model.tv?.brand == .lg && model.tvClients > 0 ? "OLED Kalkanı" : nil
            ) {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) { activeTab = .appearance }
            }

            Spacer(minLength: 8)

            // Canlı Oturum Kronometresi
            SessionClockBadge(startedAt: model.sessionStartedAt, isRunning: model.isRunning)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .tile(padding: 0)
    }

    private var engineTitle: String {
        let engine = model.settings.translationEngine
        return engine == .free ? "Apple Ücretsiz" : engine.displayName
    }

    private var packSubtitle: String {
        if model.settings.gamePacks && !model.installedPacks.isEmpty {
            return "\(model.installedPacks.count) oyun paketi açık"
        }
        return "\(model.settings.sourceLanguage.uppercased()) → \(model.settings.targetLanguage.uppercased())"
    }

    private var destinationTitle: String {
        if model.settings.output == .computer { return "Mac Ekranı" }
        if let name = model.tv?.name, !name.isEmpty { return name }
        return "LG OLED TV"
    }

    private var destinationSubtitle: String {
        if model.settings.output == .computer { return model.isRunning ? "Aktif pencere" : "Hazır" }
        if !model.hasTV { return "Bağlı değil" }
        return model.tvClients > 0 ? "Bağlı · Canlı" : "TV uygulaması bekleniyor"
    }

    private var destinationTone: StatusTone {
        if model.settings.output == .computer { return model.isRunning ? .good : .idle }
        return AppModel.tvTone(clients: model.tvClients, running: model.isRunning)
    }
}

private struct PipelineNode: View {
    let symbol: String
    let title: String
    let subtitle: String
    let tone: StatusTone
    var shieldBadge: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius("control"), style: .continuous)
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tone == .idle ? Color.csSecondary : tone.color)
                    .frame(width: 32, height: 32)
                    .background((tone == .idle ? Color.csSurface2 : tone.color.opacity(0.16)), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(verbatim: title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Color.csText)
                            .lineLimit(1)
                        if let shieldBadge {
                            HStack(spacing: 3) {
                                Image(systemName: "checkmark.shield.fill").font(.system(size: 9.5))
                                Text(verbatim: shieldBadge).font(.system(size: 10, weight: .bold))
                            }
                            .foregroundStyle(Color.csSuccess)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.csSuccessSoft.opacity(0.9), in: Capsule())
                        }
                    }
                    HStack(spacing: 5) {
                        Circle().fill(tone.color).frame(width: 6, height: 6)
                        Text(verbatim: subtitle)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.csSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(hovering ? Color.csSurface2.opacity(0.72) : Color.csSurface2.opacity(0.38), in: shape)
            .overlay(shape.strokeBorder(hovering ? Color.csAccent.opacity(0.35) : Color.csBorder.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Canlı veri akışı bağlayıcısı: yayın sürerken sinyal hattında akıcı ışık noktası taşır.
private struct SignalConnector: View {
    let active: Bool
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var travel = false

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(active ? color.opacity(0.28) : Color.csBorder.opacity(0.55))
                .frame(width: 28, height: 2.5)
            if active && !reduceMotion {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .shadow(color: color.opacity(0.8), radius: 4)
                    .offset(x: travel ? 22 : 0)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) {
                            travel = true
                        }
                    }
            }
        }
        .frame(width: 28, height: 8)
    }
}

private struct SessionClockBadge: View {
    let startedAt: Date?
    let isRunning: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = isRunning ? max(0, Int(context.date.timeIntervalSince(startedAt ?? context.date))) : 0
            let text = isRunning
                ? String(format: "%02d:%02d:%02d", elapsed / 3600, (elapsed % 3600) / 60, elapsed % 60)
                : "00:00:00"
            HStack(spacing: 6) {
                if isRunning {
                    LiveDot(color: .csSuccess)
                } else {
                    Image(systemName: "clock").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.csSecondary)
                }
                Text(verbatim: text)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isRunning ? Color.csText : Color.csSecondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color.csSurface2.opacity(0.65), in: Capsule())
            .overlay(Capsule().strokeBorder(isRunning ? Color.csSuccess.opacity(0.35) : Color.csBorder.opacity(0.5), lineWidth: 1))
        }
    }
}

// MARK: - Sinema Altyazı Sahnesi + Canlı Gecikme Grafiği

private struct CinemaStageCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let latencySamples: [Int]
    @State private var copied = false

    private var previousEntry: SubtitleHistory.Entry? {
        model.sessionHistory.count >= 2 ? model.sessionHistory[1] : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Sahne üst çubuğu
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.csAccentText)
                    Text("CANLI ALTYAZI SAHNESİ")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.0)
                        .foregroundStyle(Color.csSecondary)
                }
                if !model.sessionHistory.isEmpty {
                    Pill(text: "\(model.sessionHistory.count) replik")
                }
                Spacer()
                if !model.lastTranslation.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(model.lastTranslation)\n\(model.lastSource)", forType: .string)
                        copied = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            Text(copied ? "Kopyalandı" : "Kopyala")
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(copied ? Color.csSuccess : Color.csSecondary)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Color.csSurface2.opacity(0.8), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .resetsAfterDelay($copied)
                }
            }

            // Sinema OLED Cam Sahne Kutusu
            let stageShape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            ZStack {
                // OLED derin sinema zemini
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color(red: 0.04, green: 0.06, blue: 0.10), Color(red: 0.02, green: 0.03, blue: 0.06)]
                        : [Color(red: 0.09, green: 0.12, blue: 0.19), Color(red: 0.05, green: 0.07, blue: 0.12)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    colors: [Color.csAccent.opacity(0.16), .clear],
                    center: .bottom,
                    startRadius: 10,
                    endRadius: 340
                )

                if model.lastTranslation.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: model.isRunning ? "waveform.and.magnifyingglass" : "sparkles.tv")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(Color(red: 0.49, green: 0.83, blue: 0.99))
                            .frame(width: 58, height: 58)
                            .background(Color.white.opacity(0.07), in: Circle())
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                        Text(model.isRunning ? "Oyun altyazıları dinleniyor…" : "Stüdyo hazır — çeviri başladığında replikler burada canlanır")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .multilineTextAlignment(.center)
                        if model.isRunning && model.settings.frameSource == .ps5 && !model.demoMode {
                            Text("PS5 kolunu açarken kendi ANA hesabınızı seçin; ikinci hesap yalnız DodoSubs bağlantısı içindir.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color.white.opacity(0.58))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 460)
                        } else {
                            Text("TV'deki 60fps yukarı kaymalı yığın, gecikme grafiği ve İkiz Telefon durumu canlı takip edilir.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color.white.opacity(0.58))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 440)
                        }
                    }
                    .padding(24)
                } else {
                    VStack(spacing: 10) {
                        // Önceki satır: TV'deki yukarı kayan sönük satır hissi
                        if model.settings.style.stackPrevious, let prev = previousEntry {
                            Text(verbatim: prev.translation)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.42))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 5)
                                .background(Color.white.opacity(0.05), in: Capsule())
                        }
                        // Aktif ana replik
                        Text(verbatim: model.lastTranslation)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(
                                model.settings.style.textColor == .yellow
                                    ? Color(red: 0.99, green: 0.89, blue: 0.42)
                                    : Color(red: 0.96, green: 0.97, blue: 0.99)
                            )
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .shadow(color: .black.opacity(0.7), radius: 6, y: 2)
                            .id(model.lastTranslation)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity)
                            )
                            .textSelection(.enabled)

                        // Özgün İngilizce satır
                        Text(verbatim: model.lastSource)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(red: 0.65, green: 0.74, blue: 0.86))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                    .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.84), value: model.lastTranslation)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 196)
            .clipShape(stageShape)
            .overlay(
                stageShape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.24), Color.csAccent.opacity(0.22), .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )

            // Alt Telemetri Çipleri + Canlı Gecikme Sparkline Grafiği
            HStack(spacing: 10) {
                if let metrics = model.lastMetrics {
                    MetricsRow(metrics: metrics)
                } else {
                    TelemetryChip(icon: "bolt.fill", label: "Gecikme bekleniyor")
                }
                Spacer(minLength: 8)
                if !latencySamples.isEmpty {
                    LatencySparkline(samples: latencySamples)
                }
            }
        }
        .tile()
    }
}

/// Son 24 altyazının toplam gecikmesini gösteren Apple Pro canlı mini bar grafiği.
private struct LatencySparkline: View {
    let samples: [Int]

    var body: some View {
        HStack(spacing: 6) {
            Canvas { ctx, size in
                let count = max(1, samples.count)
                let maxVal = max(400.0, Double(samples.max() ?? 400))
                let gap: CGFloat = 2
                let barWidth = max(2.5, (size.width - CGFloat(count - 1) * gap) / CGFloat(count))
                for (i, val) in samples.enumerated() {
                    let ratio = max(0.14, min(1.0, Double(val) / maxVal))
                    let h = size.height * ratio
                    let x = CGFloat(i) * (barWidth + gap)
                    let rect = CGRect(x: x, y: size.height - h, width: barWidth, height: h)
                    let color: Color = val <= 350 ? .csSuccess : (val <= 800 ? .csAccent : .csWarning)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color.opacity(i == samples.count - 1 ? 1.0 : 0.72)))
                }
            }
            .frame(width: 96, height: 22)
            if let last = samples.last {
                Text(verbatim: "\(last)ms")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.csSecondary)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.csSurface2.opacity(0.65), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.csBorder.opacity(0.55), lineWidth: 1))
        .help(Text("Son 24 satırın anlık gecikme grafiği"))
    }
}

/// Sahne altındaki kompakt canlı diyalog akışı.
private struct LiveDialogueFeedCard: View {
    @EnvironmentObject private var model: AppModel
    let onOpenHistory: () -> Void

    var body: some View {
        let entries = Array(model.sessionHistory.dropFirst().prefix(12))
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Son Replikler")
                    .font(.csHeadline)
                Spacer()
                if !model.history.entries.isEmpty {
                    Button(action: onOpenHistory) {
                        HStack(spacing: 4) {
                            Text("Tüm Geçmiş")
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        }
                        .font(.csCaption.weight(.semibold))
                        .foregroundStyle(Color.csAccentText)
                    }
                    .buttonStyle(.plain)
                }
            }
            if entries.isEmpty {
                Text("Oturum boyunca çevrilen önceki satırlar burada akıcı zaman çizelgesi hâlinde birikir.")
                    .font(.csCallout)
                    .foregroundStyle(Color.csSecondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entries, id: \.id) { entry in
                        HistoryRow(entry: entry)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tile()
    }
}

// MARK: - Sağ Hızlı Stüdyo Kontrol Rafı (Oyun Sırasında Ayarlar'a Girilmeden Anlık Kontrol)

private struct QuickStudioRackCard: View {
    @EnvironmentObject private var model: AppModel
    @Binding var activeTab: MainView.StudioTab

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Anlık TV Kontrolü", systemImage: "dial.medium.fill")
                    .font(.csHeadline)
                    .foregroundStyle(Color.csText)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) { activeTab = .appearance }
                } label: {
                    Text("Tümü ›")
                        .font(.csCaption.weight(.semibold))
                        .foregroundStyle(Color.csAccentText)
                }
                .buttonStyle(.plain)
            }

            // 3'lü özel cam çıktı seçici (hiçbir genişlikte taşmaz)
            VStack(alignment: .leading, spacing: 6) {
                Text("Çıktı Hedefi").font(.csCaption).foregroundStyle(Color.csSecondary)
                HStack(spacing: 4) {
                    outputPill("TV", icon: "tv", tag: .tv)
                    outputPill("Mac", icon: "macwindow", tag: .computer)
                    outputPill("İkisi", icon: "rectangle.on.rectangle", tag: .both)
                }
                .padding(3)
                .background(Color.csSurface2.opacity(0.75), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.csBorder.opacity(0.6), lineWidth: 1))
            }

            // Anlık Yazı Boyutu Stepper
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Yazı Boyutu").font(.csBody.weight(.medium))
                    Text("Anında TV'ye yansır").font(.system(size: 11)).foregroundStyle(Color.csSecondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    stepButton(systemImage: "minus") {
                        model.settings.style.fontSize = max(20, model.settings.style.fontSize - 2)
                        model.sendTestSubtitle()
                    }
                    Text(verbatim: "\(model.settings.style.fontSize) px")
                        .font(.csCallout.weight(.semibold).monospacedDigit())
                        .frame(minWidth: 46)
                    stepButton(systemImage: "plus") {
                        model.settings.style.fontSize = min(80, model.settings.style.fontSize + 2)
                        model.sendTestSubtitle()
                    }
                }
            }

            // Anlık Zemin Opaklığı
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Zemin Opaklığı").font(.csCaption).foregroundStyle(Color.csSecondary)
                    Spacer()
                    Text(verbatim: "%\(model.settings.style.background)")
                        .font(.csCaption.monospacedDigit())
                        .foregroundStyle(Color.csAccentText)
                }
                Slider(
                    value: Binding(
                        get: { Double(model.settings.style.background) },
                        set: { model.settings.style.background = Int($0.rounded()) }
                    ),
                    in: 0...100
                ) {
                    Text("Background")
                } onEditingChanged: { editing in
                    if !editing { model.sendTestSubtitle() }
                }
                .tint(Color.csAccent)
            }

            Divider().overlay(Color.csBorder.opacity(0.55))

            // Hızlı tek tık stüdyo anahtarları
            VStack(spacing: 8) {
                QuickToggleRow(title: "Oyun Paketleri", subtitle: "\(model.installedPacks.count) hazır oyun", isOn: $model.settings.gamePacks)
                QuickToggleRow(title: "Yukarı Kaymalı Yığın", subtitle: "Hızlı konuşmada 3 satır", isOn: $model.settings.style.stackPrevious)
                QuickToggleRow(title: "Kalın Altyazı", subtitle: "Daha yüksek okunabilirlik", isOn: $model.settings.style.bold)
            }
        }
        .tile()
    }

    private func outputPill(_ title: String, icon: String, tag: SubtitleOutput) -> some View {
        let selected = model.settings.output == tag
        return Button {
            withAnimation(.easeOut(duration: 0.14)) { model.settings.output = tag }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(verbatim: title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(selected ? Color.csOnAccent : Color.csSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(selected ? Color.csAccent : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func stepButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.csText)
                .frame(width: 28, height: 28)
                .background(Color.csSurface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.csBorder.opacity(0.75), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct QuickToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title).font(.system(size: 13.5, weight: .medium))
                Text(verbatim: subtitle).font(.system(size: 11)).foregroundStyle(Color.csSecondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Color.csAccent)
        }
    }
}

/// İkiz Telefon & Ek Alanlar durum özeti.
private struct ExtraRegionsSummaryCard: View {
    @EnvironmentObject private var model: AppModel
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("İkiz Telefon & Alanlar", systemImage: "iphone.gen3")
                    .font(.csHeadline)
                Spacer()
                Button("Düzenle ›", action: onEdit)
                    .buttonStyle(.plain)
                    .font(.csCaption.weight(.semibold))
                    .foregroundStyle(Color.csAccentText)
            }
            if model.settings.extraAreas.isEmpty {
                Text("Oyun içi telefon mesajları veya görev kutuları için ek alan ekleyin.")
                    .font(.csCallout)
                    .foregroundStyle(Color.csSecondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.settings.extraAreas) { area in
                        HStack(spacing: 8) {
                            Image(systemName: area.presentation == .sideBubble ? "iphone" : "rectangle.dashed")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(area.enabled ? Color.csAccentText : Color.csSecondary)
                                .frame(width: 24, height: 24)
                                .background((area.enabled ? Color.csAccentSoft : Color.csSurface2).opacity(0.8), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: area.name.isEmpty ? "Ek Alan" : area.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                Text(verbatim: area.presentation == .sideBubble
                                     ? "İkiz Telefon · \(area.panelTemplates.count) şablon"
                                     : "Yerinde Çeviri")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.csSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            StatusDot(color: !area.enabled ? .csSecondary : (area.onlyWhenVisible ? .csSuccess : .csAccent))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.csSurface2.opacity(0.45), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
            }
        }
        .tile()
    }
}

/// Sağ rafta açılıp kapanabilen mini canlı PS5 akış monitörü (kapalıyken sıfır CPU yükü).
private struct CollapsiblePS5MonitorCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var preview: FramePreview
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "eye.fill" : "eye")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(expanded && model.isRunning ? Color.csAccentText : Color.csSecondary)
                    Text("Canlı PS5 Monitörü")
                        .font(.csHeadline)
                        .foregroundStyle(Color.csText)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.csSecondary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                Group {
                    if let image = preview.image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ZStack {
                            Color.csBackground.opacity(0.75)
                            Text(model.isRunning ? "Kare bekleniyor…" : "Çeviri başlatıldığında görüntü burada görünür")
                                .font(.csCaption)
                                .foregroundStyle(Color.csSecondary)
                                .multilineTextAlignment(.center)
                                .padding(12)
                        }
                        .aspectRatio(16 / 9, contentMode: .fit)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            }
        }
        .tile()
    }
}

// MARK: - 2. Canlı Monitör & Alanlar Çalışma Alanı

private struct MonitorAreasWorkspace: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Canlı Monitör & Ek Alanlar").font(.csDisplay)
                        Text("Altyazı bölgesini, İkiz Türkçe Telefon şablonunu ve akıllı panel algılamasını canlı kare üstünde ayarlayın.")
                            .font(.csCallout)
                            .foregroundStyle(Color.csSecondary)
                    }
                    Spacer()
                    Button { model.translateScreen() } label: {
                        Label("Ekranı Çevir (⌥⌘T)", systemImage: "text.viewfinder")
                    }
                    .buttonStyle(.secondary)
                    .disabled(!model.isRunning)
                }
                AreaCards()
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 24)
        }
    }
}

// MARK: - 3. Altyazı & TV Çalışma Alanı (Canlı 16:9 OLED TV Önizleyici + 4 Sinema Ön Ayarı!)

private struct AppearanceTVWorkspace: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Altyazı & TV Stüdyosu").font(.csDisplay)
                    Text("Tüm değişiklikler aşağıdaki canlı OLED önizlemede ve bağlı LG TV'nizde anında güncellenir.")
                        .font(.csCallout)
                        .foregroundStyle(Color.csSecondary)
                }

                // Canlı İnteraktif 16:9 LG OLED TV Simülatörü + 4 Sinema Ön Ayarı
                LiveOLEDPreviewCard()

                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 14) {
                        AppearanceCard()
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 14) {
                        SubtitleOutputCard(detailed: true)
                        TVAppCard()
                    }
                    .frame(width: 340)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 24)
        }
    }
}

private struct LiveOLEDPreviewCard: View {
    @EnvironmentObject private var model: AppModel

    private struct CinemaPreset: Identifiable {
        let id: String
        let title: String
        let detail: String
        let fontSize: Int
        let background: Int
        let shape: SubtitleBackgroundShape
        let placement: SubtitlePlacement
        let color: SubtitleTextColor
        let bold: Bool
        let stack: Bool
    }

    private let presets: [CinemaPreset] = [
        .init(id: "oled", title: "Sinema OLED", detail: "46px · Yumuşak · Beyaz", fontSize: 46, background: 28, shape: .fit, placement: .cover, color: .white, bold: false, stack: true),
        .init(id: "yellow", title: "Klasik Sarı", detail: "48px · Sıcak Sarı", fontSize: 48, background: 36, shape: .fit, placement: .cover, color: .yellow, bold: false, stack: true),
        .init(id: "band", title: "Tam Örtücü", detail: "50px · Koyu Bant · Kalın", fontSize: 50, background: 86, shape: .band, placement: .cover, color: .white, bold: true, stack: true),
        .init(id: "minimal", title: "Saf Minimal", detail: "44px · Şeffaf · Üstte", fontSize: 44, background: 0, shape: .fit, placement: .above, color: .white, bold: false, stack: true),
    ]

    var body: some View {
        let style = model.settings.style
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Canlı LG OLED TV Önizlemesi", systemImage: "tv.inset.filled")
                    .font(.csHeadline)
                Spacer()
                Button {
                    model.sendTestSubtitle()
                } label: {
                    Label("Gerçek TV'de Göster", systemImage: "paperplane.fill")
                }
                .buttonStyle(.secondary)
            }

            // 16:9 Mini OLED TV Çerçevesi
            GeometryReader { geo in
                let scale = max(0.32, geo.size.height / 1080.0)
                let fontPx = max(11, CGFloat(style.fontSize) * scale * 1.15)
                let bgOpacity = Double(style.background) / 100.0
                let subColor: Color = style.textColor == .yellow
                    ? Color(red: 0.99, green: 0.89, blue: 0.42)
                    : Color(red: 0.96, green: 0.97, blue: 0.99)
                let previewText = model.lastTranslation.isEmpty
                    ? "Beş dakika olmaz, iki dakikan var. Arabaları hallet yeter!"
                    : model.lastTranslation

                ZStack {
                    // Sinematik gece oyun sahnesi arka planı
                    LinearGradient(
                        colors: [
                            Color(red: 0.06, green: 0.10, blue: 0.18),
                            Color(red: 0.11, green: 0.08, blue: 0.16),
                            Color(red: 0.03, green: 0.04, blue: 0.07),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    // Hafif şehir ufuk ışıltısı
                    RadialGradient(
                        colors: [Color(red: 0.98, green: 0.45, blue: 0.28).opacity(0.20), .clear],
                        center: UnitPoint(x: 0.72, y: 0.44),
                        startRadius: 10,
                        endRadius: geo.size.width * 0.45
                    )
                    RadialGradient(
                        colors: [Color.csAccent.opacity(0.18), .clear],
                        center: UnitPoint(x: 0.25, y: 0.35),
                        startRadius: 10,
                        endRadius: geo.size.width * 0.42
                    )

                    // Köşe HUD göstergesi
                    VStack {
                        HStack {
                            Text(verbatim: "4K HDR · 60 FPS")
                                .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                                .foregroundStyle(Color.white.opacity(0.45))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.35), in: Capsule())
                            Spacer()
                            Text(verbatim: "DodoSubs TV")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Color.csAccent.opacity(0.8))
                        }
                        .padding(12)
                        Spacer()
                    }

                    // Oyunun kendi İngilizce altyazısı (yerleşim etkisini canlı gösterir)
                    VStack {
                        Spacer()
                        Text(verbatim: "Five minutes, no good. You got two. Just take out the cars!")
                            .font(.system(size: max(9, fontPx * 0.68), weight: .medium))
                            .foregroundStyle(Color.white.opacity(style.placement == .cover && style.background >= 75 ? 0.12 : 0.45))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 4))
                            .padding(.bottom, geo.size.height * 0.09)
                    }

                    // Canlı DodoSubs Türkçe Altyazı katmanı
                    VStack(spacing: 4) {
                        Spacer()
                        if style.stackPrevious {
                            Text(verbatim: "Neler oluyor dostum?")
                                .font(.system(size: max(9.5, fontPx * 0.78), weight: style.bold ? .bold : .medium))
                                .foregroundStyle(subColor.opacity(0.68))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(bgOpacity * 0.65), in: RoundedRectangle(cornerRadius: 6))
                        }
                        Text(verbatim: previewText)
                            .font(.system(size: fontPx, weight: style.bold ? .bold : .semibold))
                            .foregroundStyle(subColor)
                            .multilineTextAlignment(.center)
                            .shadow(color: .black.opacity(0.9), radius: style.background < 20 ? 4 : 1.5, y: 1.5)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .frame(maxWidth: style.backgroundShape == .band ? .infinity : nil)
                            .background(
                                Color.black.opacity(bgOpacity),
                                in: RoundedRectangle(cornerRadius: style.backgroundShape == .band ? 0 : 8, style: .continuous)
                            )
                    }
                    .padding(.bottom, subtitleBottomOffset(height: geo.size.height, style: style))
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.20), lineWidth: 1.5)
                )
            }
            .frame(height: 218)

            // 4 Tek-Tık Sinema Ön Ayarı
            HStack(spacing: 8) {
                ForEach(presets) { preset in
                    let active = style.fontSize == preset.fontSize && style.textColor == preset.color && style.backgroundShape == preset.shape && abs(style.background - preset.background) <= 6
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) {
                            model.settings.style.fontSize = preset.fontSize
                            model.settings.style.background = preset.background
                            model.settings.style.backgroundShape = preset.shape
                            model.settings.style.placement = preset.placement
                            model.settings.style.textColor = preset.color
                            model.settings.style.bold = preset.bold
                            model.settings.style.stackPrevious = preset.stack
                        }
                        model.sendTestSubtitle()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(preset.color == .yellow ? Color(red: 0.99, green: 0.89, blue: 0.42) : Color.white)
                                    .frame(width: 8, height: 8)
                                    .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
                                Text(verbatim: preset.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.csText)
                                Spacer(minLength: 0)
                                if active {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.csAccentText)
                                }
                            }
                            Text(verbatim: preset.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.csSecondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(active ? Color.csAccentSoft.opacity(0.82) : Color.csSurface2.opacity(0.55))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(active ? Color.csAccent : Color.csBorder.opacity(0.55), lineWidth: active ? 1.5 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .tile()
    }

    private func subtitleBottomOffset(height: CGFloat, style: SubtitleStyle) -> CGFloat {
        switch style.placement {
        case .cover: height * 0.08
        case .above: height * 0.22
        case .below: height * 0.02
        case .fixed: height * CGFloat(max(2, min(72, style.bottomPercent))) / 100.0
        }
    }
}

// MARK: - 4. Çeviri Motoru & Oyun Paketleri Çalışma Alanı

private struct EnginePacksWorkspace: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Çeviri Motoru & Oyun Paketleri").font(.csDisplay)
                    Text("Yapay zekâ / DeepL çeviri motorunuzu seçin, oyun dilini belirleyin ve hazır Türkçe oyun paketlerini yönetin.")
                        .font(.csCallout)
                        .foregroundStyle(Color.csSecondary)
                }
                TranslationCard()
                LanguageCard()
                GamePacksPage()
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 24)
        }
    }
}

// MARK: - 5. PS5, Dublaj, OBS & Sistem Çalışma Alanı

private struct HardwareSystemWorkspace: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PS5, Ses & Sistem").font(.csDisplay)
                    Text("Görüntü kaynağı, Türkçe yapay zekâ dublaj, OBS yayın penceresi, PS5 giriş şifresi ve stüdyo teması.")
                        .font(.csCallout)
                        .foregroundStyle(Color.csSecondary)
                }
                FrameSourceCard()
                DubbingCard()
                OBSCard()
                LoginPasscodeCard()
                DemoModeCard()
                AppThemeCard()
                AboutCard()
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Paylaşılan Bileşenler & Test Uyumluluk Görünümleri (`MainLayoutTests`)

/// `MainLayoutTests` için dar/standart sütun ölçümünü koruyan kontrol sütunu.
struct ControlsColumn: View {
    let width: CGFloat

    var body: some View {
        ScrollView {
            MainControls()
                .padding(.vertical, Theme.space("m"))
                .frame(width: width)
        }
        .scrollIndicators(.never)
        .padding(.vertical, -Theme.space("m"))
        .frame(width: width)
    }
}

/// `MainLayoutTests` ve kompakt düzen için sol kontrol kümesi.
struct MainControls: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space("gap")) {
            HStack(spacing: Theme.space("m")) {
                StartStopButton()
                TestSubtitleButton()
            }
            HStack(alignment: .top, spacing: Theme.space("gap")) {
                if model.demoMode {
                    StatusTile(symbol: "play.rectangle", title: "Demo mode", value: model.ps5StatusText,
                               tone: AppModel.ps5Tone(model.sessionState, running: model.isRunning))
                } else {
                    StatusTile(symbol: "gamecontroller.fill", title: "PS5", value: model.ps5StatusText,
                               subtitle: model.console?.name,
                               tone: AppModel.ps5Tone(model.sessionState, running: model.isRunning))
                }
                if model.settings.output.showsOnTV { TVStatusTile() }
            }
            .fixedSize(horizontal: false, vertical: true)
            if model.isRunning && !model.demoMode { GameSection(choice: model.gameChoice, areas: model.gameAreas) }
            if !model.canStart && !model.isRunning && !model.demoMode { DemoModeButton(kind: .ghost) }
            SubtitleOutputCard()
            InfoCard {
                InfoRow("Picture source", value: pictureSourceName, action: { model.openSettings(.source) })
                InfoDivider()
                InfoRow("Translation", value: engineName, action: { model.openSettings(.translation) })
                InfoDivider()
                InfoRow("Translate screen") { Keycap("⌥⌘T") }
            }
            MainWarnings()
        }
    }

    private var pictureSourceName: String {
        model.settings.frameSource == .remotePlayWindow
            ? String(localized: "Remote Play window on this Mac") : String(localized: "The PS5 (second account)")
    }

    private var engineName: String {
        let engine = model.settings.translationEngine
        return engine == .free ? String(localized: "Free") : engine.displayName
    }
}

private struct StartStopButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            if model.demoMode {
                model.exitDemo()
            } else {
                Task { model.isRunning ? model.stop() : await model.start() }
            }
        } label: {
            Group {
                if model.demoMode {
                    Label("Exit demo mode", systemImage: "xmark")
                } else {
                    Label(model.isRunning ? "Stop translating" : "Start translating",
                          systemImage: model.isRunning ? "stop.fill" : "play.fill")
                }
            }
            .font(.csHeadline)
        }
        .buttonStyle(CSButtonStyle(kind: model.isRunning || model.demoMode ? .danger : .primary, fullWidth: true, height: "primaryActionHeight"))
        .disabled(model.isStarting || (!model.isRunning && !model.canStart && !model.demoMode))
    }
}

private struct TestSubtitleButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let onTV = model.settings.output.showsOnTV
        Button {
            Task { await model.testSubtitle() }
        } label: {
            if model.openingTVAppForTest {
                Label("Opening the app on the TV…", systemImage: "tv")
            } else {
                Label(onTV ? "Test on TV" : "Test on screen", systemImage: onTV ? "tv" : "macwindow")
            }
        }
        .buttonStyle(CSButtonStyle(kind: .secondary, height: "primaryActionHeight"))
        .fixedSize()
        .disabled((onTV && !model.hasTV && !model.settings.output.showsOnComputer) || model.openingTVAppForTest)
        .help(Text(onTV ? "Sends a sample subtitle to the TV." : "Shows a sample subtitle on this computer's screen."))
    }
}

private struct TVStatusTile: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.hasTV {
            if model.canReinstallTVApp {
                StatusTile(symbol: "tv.fill", title: "TV", value: String(localized: "Waiting for the TV app"),
                           subtitle: model.tv?.name,
                           tone: AppModel.tvTone(clients: model.tvClients, running: model.isRunning)) {
                    Button("Reinstall the TV app") {
                        model.step = .tv
                        Task { await model.reinstallTVApp() }
                    }.buttonStyle(.secondary)
                }
            } else {
                StatusTile(symbol: "tv.fill", title: "TV",
                           value: model.tvClients > 0 ? String(localized: "Connected") : String(localized: "Waiting for the TV app"),
                           subtitle: model.tv?.name,
                           tone: AppModel.tvTone(clients: model.tvClients, running: model.isRunning))
            }
        } else {
            StatusTile(symbol: "tv", title: "TV", value: String(localized: "Not set up")) {
                Button("Connect a TV") { model.step = .tv }.buttonStyle(.secondary)
            }
        }
    }
}

/// Dil paketi eksik, çevrimiçi motor çeviremiyor, macOS yazıyı okuyamıyor.
private struct MainWarnings: View {
    @EnvironmentObject private var model: AppModel

    private var sourceName: String { Locale.current.localizedString(forLanguageCode: model.settings.sourceLanguage) ?? model.settings.sourceLanguage }
    private var targetName: String { Locale.current.localizedString(forLanguageCode: model.settings.targetLanguage) ?? model.settings.targetLanguage }

    var body: some View {
        if model.translatorStatus != .ready {
            Card {
                if model.translatorStatus == .needsDownload {
                    Label(String(format: String(localized: "The %@–%@ language pack is not downloaded yet."), sourceName, targetName),
                          systemImage: "arrow.down.circle")
                        .font(.csBody.weight(.semibold))
                        .foregroundStyle(Color.csWarning)
                    HintText(text: "Open System Settings › General › Language & Region › Translation Languages and download both languages.")
                    Button("Open Language & Region") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
                    }
                    .buttonStyle(.secondary)
                } else {
                    Label(String(format: String(localized: "Translation from %@ to %@ is not available on this Mac."), sourceName, targetName),
                          systemImage: "exclamationmark.triangle")
                        .font(.csBody.weight(.semibold))
                        .foregroundStyle(Color.csWarning)
                    if !Translator.isAvailable {
                        HintText(text: "Apple's free translation needs macOS 26 or later. Game packs, DeepL and AI translation (Settings › Translation) work on this Mac.")
                    }
                }
            }
        }

        if model.isRunning, let issue = model.onlineIssue {
            Card {
                Label(String(format: String(localized: "%@ is not translating right now"), model.settings.onlineEngine.displayName),
                      systemImage: "exclamationmark.triangle")
                    .font(.csBody.weight(.semibold))
                    .foregroundStyle(Color.csWarning)
                Text(verbatim: TranslationCard.describe(issue, engine: model.settings.onlineEngine, server: model.settings.localAIServer) + " "
                     + String(localized: "Meanwhile the free translation is used."))
                    .font(.csCallout)
                    .foregroundStyle(Color.csSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if let free = model.readingFailedFreeGB {
            Card {
                Label("macOS can't read the text on the screen.", systemImage: "exclamationmark.triangle")
                    .font(.csBody.weight(.semibold))
                    .foregroundStyle(Color.csWarning)
                if free < 10 {
                    HintText(text: LocalizedStringKey(String(format: String(localized: "The disk is almost full (%.1f GB free). macOS needs free space to read text; free up a few GB and start the translation again."), free)))
                } else {
                    HintText(text: "Restart the Mac and start the translation again.")
                }
            }
        }
    }
}

/// Son satırın ölçümleri: Apple Pro Liquid Glass telemetri çipleri.
struct MetricsRow: View {
    let metrics: LineMetrics

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if metrics.origin == .pack {
                    TelemetryChip(icon: "shippingbox.fill", label: String(localized: "Pack"), tint: .csPro, softFill: .csProSoft)
                } else {
                    TelemetryChip(icon: "sparkles", label: String(localized: "Translation engine"), tint: .csAccentText, softFill: .csAccentSoft)
                }
                if let ocr = metrics.ocrMs {
                    TelemetryChip(icon: "eye", label: "OCR \(ocr) ms")
                }
                if let tr = metrics.translationMs {
                    TelemetryChip(icon: "globe", label: "Çeviri \(tr) ms")
                }
                TelemetryChip(
                    icon: "bolt.fill",
                    label: "\(metrics.totalMs) ms",
                    tint: latencyColor,
                    softFill: latencySoftFill
                )
                if let conf = metrics.confidence {
                    TelemetryChip(icon: "checkmark.seal", label: "%\(conf)")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Measurements"))
        .accessibilityValue(Text(verbatim: metrics.summary))
    }

    private var latencyColor: Color {
        if metrics.totalMs <= 350 { return .csSuccess }
        if metrics.totalMs <= 800 { return .csAccentText }
        return .csWarning
    }

    private var latencySoftFill: Color {
        if metrics.totalMs <= 350 { return .csSuccessSoft }
        if metrics.totalMs <= 800 { return .csAccentSoft }
        return .csSurface2
    }
}

private struct HistoryRow: View {
    let entry: SubtitleHistory.Entry
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.space("s")) {
            Circle()
                .fill(entry.origin == .pack ? Color.csPro : Color.csAccentText)
                .frame(width: 6, height: 6)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.translation)
                    .font(.csBody.weight(.medium))
                    .foregroundStyle(Color.csText.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(verbatim: entry.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.csSecondary.opacity(0.8))
                    Text(verbatim: "·")
                        .foregroundStyle(Color.csSecondary.opacity(0.6))
                    Text(verbatim: entry.source)
                        .font(.csCaption)
                        .foregroundStyle(Color.csSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 4)
            if hovering || copied {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(entry.translation)\n\(entry.source)", forType: .string)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(copied ? Color.csSuccess : Color.csSecondary)
                }
                .buttonStyle(.plain)
                .resetsAfterDelay($copied)
            }
        }
        .padding(.horizontal, Theme.space("m"))
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius("inner"), style: .continuous)
                .fill(hovering ? Color.csSurface2.opacity(0.65) : Color.csSurface2.opacity(0.32))
        )
        .onHover { hovering = $0 }
    }
}
