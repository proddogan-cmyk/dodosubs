// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Theme.space("m")) {
            LogoView(size: 92)
            VStack(spacing: 4) {
                Text(verbatim: "DodoSubs").font(.csDisplay)
                HStack(spacing: 8) {
                    Text(verbatim: "LIQUID GLASS STUDIO")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.1)
                        .foregroundStyle(Color.csAccentText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.csAccentSoft.opacity(0.9), in: Capsule())
                    Text(verbatim: "v\(AppIdentity.version)")
                        .font(.csCaption.monospacedDigit())
                        .foregroundStyle(Color.csSecondary)
                }
            }
            VStack(spacing: 6) {
                Text("PS5 ve LG OLED TV için canlı Türkçe altyazı ve İkiz Telefon stüdyosu.")
                    .font(.csBody)
                    .multilineTextAlignment(.center)
                Text("GNU AGPL-3.0 açık kaynak lisansı altında CouchSubs ve chiaki-ng altyapısı üzerine geliştirilmiştir.")
                    .font(.csCallout)
                    .foregroundStyle(Color.csSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(Theme.space("m"))
            .frame(maxWidth: .infinity)
            .tile(padding: Theme.space("m"))
            HStack(spacing: Theme.space("m")) {
                Link("Source code", destination: AppIdentity.sourceURL)
                Text(verbatim: "·").foregroundStyle(Color.csSecondary)
                Link(destination: URL(string: "https://github.com/chiaki-ng/chiaki-ng")!) { Text(verbatim: "chiaki-ng") }
            }
            .foregroundStyle(Color.csAccentText)
            Text("DodoSubs, Sony Interactive Entertainment ile ilişkili değildir. PlayStation ve PS5, Sony Interactive Entertainment Inc.'in ticari markalarıdır.")
                .font(.csCaption)
                .foregroundStyle(Color.csSecondary)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .buttonStyle(CSButtonStyle(kind: .primary, height: "buttonLarge"))
                .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.space("xxl"))
        .frame(width: 480)
    }
}
