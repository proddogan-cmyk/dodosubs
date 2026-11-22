// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import RemotePlay
import SwiftUI

/// DodoSubs Ana Stüdyo Ekranı: üstte Liquid Glass komut çubuğu, solda kontrol güvertesi ve durum karoları,
/// sağda isteğe bağlı canlı PS5 monitörü, telemetri şeridi ve sinematik canlı altyazı sahnesi.
struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showLiveMonitor = false

    /// Sol sütunun en dar hâli (iki durum karosu yan yana okunur kalır).
    static let controlsColumnMin: CGFloat = 340
    /// Canlı altyazı sütununun en dar hâli.
    static let liveColumnMin: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space("gap")) {
            MainHeader(showLiveMonitor: $showLiveMonitor)
            GeometryReader { geometry in
                let gap = Theme.space("gap")
                let available = geometry.size.width
                if available >= Self.controlsColumnMin + gap + Self.liveColumnMin {
                    HStack(alignment: .top, spacing: gap) {
                        ControlsColumn(width: min(Theme.size("mainColumn"), available - gap - Self.liveColumnMin))
                        VStack(alignment: .leading, spacing: gap) {
                            if model.demoMode {
                                DemoFrameTile(preview: model.framePreview)
                            } else if showLiveMonitor && model.isRunning {
                                LiveStreamMonitorTile(preview: model.framePreview) {
                                    withAnimation(.easeOut(duration: 0.2)) { showLiveMonitor = false }
                                }
                            }
                            PackInUseTile()
                            LiveSubtitlesTile()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: gap) {
                            MainControls()
                            if model.demoMode {
                                DemoFrameTile(preview: model.framePreview)
                            } else if showLiveMonitor && model.isRunning {
                                LiveStreamMonitorTile(preview: model.framePreview) {
                                    withAnimation(.easeOut(duration: 0.2)) { showLiveMonitor = false }
                                }
                            }
                            PackInUseTile()
                            LiveSubtitlesTile().frame(minHeight: Self.liveColumnMin)
                        }
                        // Kaydırma alanı içeriğe genişlik önermeyebilir; genişlik sabitlenmezse yazılar satıra inmez.
                        .frame(width: available)
                    }
                    .scrollIndicators(.never)
                }
            }
        }
        .padding(Theme.space("screen"))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $model.showSettings, onDismiss: { model.settingsSection = .appearance }) {
            SettingsView(section: model.settingsSection).appSurface()
        }
        .sheet(isPresented: $model.showHistory) { HistoryView().appSurface() }
    }
}

/// Üst Liquid Glass stüdyo komut çubuğu: DS logosu, DodoSubs adı, canlı durum rozeti ve hızlı stüdyo düğmeleri.
private struct MainHeader: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showLiveMonitor: Bool

    var body: some View {
        HStack(spacing: Theme.space("m")) {
            LogoView(size: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(verbatim: "DodoSubs").font(.csTitle)
                    Text(verbatim: "STUDIO")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.1)
                        .foregroundStyle(Color.csAccentText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.csAccentSoft.opacity(0.9), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.csAccent.opacity(0.28), lineWidth: 1))
                }
                HStack(spacing: 6) {
                    if model.isRunning {
                        LiveDot(color: .csSuccess)
                        Text(verbatim: liveRouteLabel)
                            .font(.csCaption)
                            .foregroundStyle(Color.csSecondary)
                    } else {
                        StatusDot(color: .csSecondary.opacity(0.6))
                        Text("Hazır")
                            .font(.csCaption)
                            .foregroundStyle(Color.csSecondary)
                    }
                }
            }
            Spacer()
            HStack(spacing: Theme.space("s")) {
                if !model.demoMode {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { showLiveMonitor.toggle() }
                    } label: {
                        Image(systemName: showLiveMonitor ? "eye.fill" : "eye")
                            .foregroundStyle(showLiveMonitor && model.isRunning ? Color.csAccentText : Color.csText)
                    }
                    .buttonStyle(.secondary)
                    .disabled(!model.isRunning)
                    .help(Text("Canlı PS5 akış önizlemesini aç/kapat"))
                    .accessibilityLabel(Text("Canlı önizleme"))
                }
                Button { model.translateScreen() } label: {
                    Image(systemName: "text.viewfinder")
                }
                .buttonStyle(.secondary)
                .disabled(!model.isRunning)
                .help(Text("Ekranı şimdi çevir (⌥⌘T)"))
                .accessibilityLabel(Text("Translate screen"))
                Button { model.showHistory = true } label: {
                    HStack(spacing: 6) {
                        Label("History", systemImage: "clock.arrow.circlepath")
                        if !model.history.entries.isEmpty {
                            Text(verbatim: "\(model.history.entries.count)")
                                .font(.csCaption.monospacedDigit())
                                .foregroundStyle(Color.csSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.csBackground.opacity(0.55), in: Capsule())
                        }
                    }
                }
                .buttonStyle(.secondary)
                .help(Text("History"))
                Button { model.showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.secondary)
                .help(Text("Settings"))
            }
        }
        .padding(.horizontal, Theme.space("tile"))
        .padding(.vertical, Theme.space("m"))
        .tile(padding: 0)
    }

    private var liveRouteLabel: String {
        let source = model.demoMode ? "Demo" : (model.console?.name.isEmpty == false ? model.console!.name : "PS5")
        let dest = switch model.settings.output {
        case .tv: model.tv?.name.isEmpty == false ? model.tv!.name : "TV"
        case .computer: "Mac"
        case .both: "TV + Mac"
        }
        return "\(source) → \(dest)"
    }
}

/// İsteğe bağlı canlı PS5 akış monitörü (yalnız göz simgesi açılınca çizilir; kapalıyken sıfır ek yük).
private struct LiveStreamMonitorTile: View {
    @ObservedObject var preview: FramePreview
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space("s")) {
            HStack(spacing: 8) {
                LiveDot(color: .csAccent)
                Text("Canlı PS5 Monitörü")
                    .font(.csCaption.weight(.semibold))
                    .foregroundStyle(Color.csText)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.csSecondary)
                        .frame(width: 22, height: 22)
                        .background(Color.csSurface2.opacity(0.8), in: Circle())
                }
                .buttonStyle(.plain)
                .help(Text("Önizlemeyi kapat"))
            }
            Group {
                if let image = preview.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.radius("inner"), style: .continuous)
                            .fill(Color.csBackground.opacity(0.75))
                        ProgressView().controlSize(.small)
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 200)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius("inner"), style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius("inner"), style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
        }
        .tile(padding: Theme.space("m"))
    }
}

/// Sol sütun, kendi genişliğinde kayan. İçerik genişliği sabitlenir ki dar/geniş geçişlerde taşmasın.
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

/// Sol kontrol güvertesi: başlat/durdur, PS5 ve TV cam durum karoları, oyun/alanlar, çıktı ve hızlı ayarlar.
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
                // Altyazı yalnız bilgisayar ekranındaysa TV durumu gösterilmez.
                if model.settings.output.showsOnTV { TVStatusTile() }
            }
            .fixedSize(horizontal: false, vertical: true)
            if model.isRunning && !model.demoMode { GameSection(choice: model.gameChoice, areas: model.gameAreas) }
            // Kurulum bitmeden de uygulama örnek görüntülerle denenebilir.
            if !model.canStart && !model.isRunning && !model.demoMode { DemoModeButton(kind: .ghost) }
            SubtitleOutputCard()
            InfoCard {
                InfoRow("Picture source", value: pictureSourceName, action: { model.openSettings(.source) })
                InfoDivider()
                InfoRow("Translation", value: engineName, action: { model.openSettings(.translation) })
                InfoDivider()
                InfoRow("Subtitle area", value: areasSummary, action: { model.openSettings(.area) })
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

    private var areasSummary: String {
        let extra = model.settings.extraAreas.count
        return extra > 0 ? "Altyazı + \(extra) ek alan" : "Altyazı"
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

/// Başlat düğmesinin yanında: deneme altyazısını TV'ye (ya da bilgisayar ekranına) gönderir.
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
                           tone: AppModel.tvTone(clients: model.tvClients, running: model.isRunning)) {
                    if model.isRunning && model.tv?.brand == .lg && model.tvClients > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(verbatim: "OLED Kalkanı")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Color.csSuccess)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.csSuccessSoft.opacity(0.85), in: Capsule())
                    }
                }
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

        // Çevrimiçi motor çeviremiyor: satırlar bu arada ücretsiz çeviriyle geliyor.
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

/// Hazır Türkçe çevirisi olan oyunlar kullanılıyor (yalnız İngilizce→Türkçede ve ayar açıkken).
private struct PackInUseTile: View {
    @EnvironmentObject private var model: AppModel

    private var active: Bool {
        model.settings.gamePacks && model.settings.sourceLanguage == "en" && model.settings.targetLanguage == "tr"
            && !model.installedPacks.isEmpty
    }

    var body: some View {
        if active {
            HStack(spacing: Theme.space("m")) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.csPro)
                    .frame(width: 26, height: 26)
                    .background(Color.csProSoft.opacity(0.9), in: RoundedRectangle(cornerRadius: Theme.radius("tag"), style: .continuous))
                Text(verbatim: String(format: String(localized: "Game packs are on · %lld games translated in advance"), model.installedPacks.count))
                    .font(.csBody)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tile(padding: Theme.space("m"))
        }
    }
}

/// Sağ sütun: Sinematik canlı altyazı sahnesi, Liquid Glass telemetri çipleri ve akıcı oturum geçmişi.
private struct LiveSubtitlesTile: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space("m")) {
            HStack(spacing: Theme.space("s")) {
                Text("Live subtitles").font(.csHeadline)
                if !model.sessionHistory.isEmpty {
                    Pill(text: "\(model.sessionHistory.count) satır")
                }
                Spacer()
                if model.isRunning { Pill(text: String(localized: "Translating…"), live: true) }
            }
            if model.lastTranslation.isEmpty {
                VStack(spacing: Theme.space("m")) {
                    Spacer(minLength: 24)
                    Image(systemName: model.isRunning ? "waveform.and.magnifyingglass" : "captions.bubble")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(model.isRunning ? Color.csAccentText : Color.csSecondary)
                        .frame(width: 60, height: 60)
                        .background(
                            Circle()
                                .fill(model.isRunning ? Color.csAccentSoft.opacity(0.75) : Color.csSurface2.opacity(0.75))
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                        )
                    VStack(spacing: 6) {
                        Text(model.isRunning ? "Altyazılar dinleniyor…" : "Subtitles will appear here while you play.")
                            .font(.csHeadline)
                            .foregroundStyle(Color.csText)
                            .multilineTextAlignment(.center)
                        if model.isRunning && model.settings.frameSource == .ps5 && !model.demoMode {
                            HintText(text: "When you turn on the controller to play, choose your MAIN account on the PS5. Don't play with the second account CouchSubs signs in with, or the controller won't work in the game.")
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 420)
                        } else {
                            Text("Başlat'a bastığınızda çevrilen her replik ve gecikme ölçümü burada canlı akacak.")
                                .font(.csCallout)
                                .foregroundStyle(Color.csSecondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 380)
                        }
                    }
                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Hero sinematik altyazı sahnesi: yumuşak yukarı kayma + cam vurgusu
                ZStack(alignment: .topLeading) {
                    CurrentLine(translation: model.lastTranslation, source: model.lastSource)
                        .id(model.lastTranslation)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .opacity.combined(with: .offset(y: 10)),
                                    removal: .opacity
                                )
                        )
                }
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86), value: model.lastTranslation)
                if let metrics = model.lastMetrics { MetricsRow(metrics: metrics) }
                SubtitleHistoryList()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile()
    }
}

/// Öne çıkan son çeviri sahnesi: sol safir cam şeridi, net tipografi ve tek tık kopyalama.
private struct CurrentLine: View {
    let translation: String
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius("control"), style: .continuous)
        HStack(alignment: .top, spacing: Theme.space("m")) {
            Capsule()
                .fill(LinearGradient(colors: [Color.csAccentHi, Color.csAccent], startPoint: .top, endPoint: .bottom))
                .frame(width: 3.5)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: translation)
                    .font(.csDisplay)
                    .foregroundStyle(Color.csText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: source)
                    .font(.csCaption)
                    .foregroundStyle(Color.csSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(translation)\n\(source)", forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(copied ? Color.csSuccess : Color.csSecondary)
                    .frame(width: 28, height: 28)
                    .background(Color.csSurface2.opacity(0.75), in: RoundedRectangle(cornerRadius: Theme.radius("inner"), style: .continuous))
            }
            .buttonStyle(.plain)
            .help(Text(copied ? "Copied" : "Copy"))
            .resetsAfterDelay($copied)
        }
        .padding(Theme.space("l"))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            shape.fill(colorScheme == .dark ? Color.csBackground.opacity(0.58) : Color.csSurface2.opacity(0.55))
        )
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [Color.csAccent.opacity(0.32), Color.csBorder.opacity(0.45)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        )
    }
}

/// Son satırın ölçümleri: Apple Pro Liquid Glass telemetri çipleri (kaynak, OCR, çeviri, toplam gecikme, güven).
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

/// Kaçırılan satır buradan yeniden okunur (en yenisi üstte; yalnız bu oturumun satırları).
private struct SubtitleHistoryList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let entries = Array(model.sessionHistory.dropFirst())
        if !entries.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.space("s")) {
                    ForEach(entries, id: \.id) { entry in
                        HistoryRow(entry: entry)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .accessibilityLabel(Text("Subtitle history"))
        }
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
                    .foregroundStyle(Color.csText.opacity(0.84))
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
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius("inner"), style: .continuous)
                .fill(hovering ? Color.csSurface2.opacity(0.65) : Color.csSurface2.opacity(0.32))
        )
        .onHover { hovering = $0 }
    }
}
