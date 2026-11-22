// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import SwiftUI

@main
struct CouchSubsApp: App {
    @StateObject private var model = Self.makeModel()
    /// Bilgisayar ekranındaki altyazı penceresi.
    @State private var overlay = SubtitleOverlayController()
    /// Yayın programlarının yakaladığı düz zeminli altyazı penceresi (Ayarlar > OBS'ten açılır).
    @State private var stream = StreamWindowController()

    /// Testler uygulamanın içinde çalışır. Gerçek Anahtarlığa dokunmazlar: imza farklı olunca macOS parola sorar ve test takılır.
    private static func makeModel() -> AppModel {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? AppModel() : AppModel(store: EphemeralStore())
    }

    var body: some Scene {
        WindowGroup("DodoSubs") {
            RootView()
                .environmentObject(model)
                .task {
                    overlay.attach(model)
                    stream.attach(model)
                }
                .appSurface()
                .frame(minWidth: Theme.size("windowWidth"), idealWidth: Theme.size("windowWidth"), maxWidth: Theme.size("windowWidth") * 1.3,
                       minHeight: Theme.size("windowHeight"), idealHeight: Theme.size("windowHeight"))
                // Başlık çubuğu da pencere zemininin rengini alır (macOS 15 ve sonrası; öncesinde sistem rengi).
                .windowBackground(Color.csBackground)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("DodoSubs Hakkında") { model.showAbout = true }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings") { model.showSettings = true }
                    .keyboardShortcut(",")
                    .disabled(model.step != .done)
            }
        }
        // Altyazı bilgisayar ekranındayken menü çubuğundan pencereye ulaşılır ("Tıklamalar geçsin" açıkken geri dönüş yolu).
        MenuBarExtra("DodoSubs", systemImage: "captions.bubble",
                     isInserted: Binding(get: { model.step == .done && model.settings.output.showsOnComputer }, set: { _ in })) {
            Toggle("Clicks pass through", isOn: Binding(get: { model.settings.overlayClickThrough },
                                                        set: { model.settings.overlayClickThrough = $0 }))
            Button("Adjust the subtitle window") { model.overlayAdjusting = true }
            Divider()
            Button("DodoSubs'ı Aç") {
                if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            // Deneme modu kurulumdan bağımsızdır: sihirbazın hangi adımından açılırsa açılsın ana pencere görünür.
            if model.step == .done || model.demoMode { MainView() } else { OnboardingView() }
        }
        .sheet(isPresented: $model.showAbout) { AboutView().appSurface() }
    }
}

private extension View {
    /// Pencere zemini; `containerBackground(_:for: .window)` macOS 15'te geldi.
    @ViewBuilder func windowBackground(_ color: Color) -> some View {
        if #available(macOS 15, *) {
            containerBackground(color, for: .window)
        } else {
            self
        }
    }
}
