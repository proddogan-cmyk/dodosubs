// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct WelcomeStep: View {
    var body: some View {
        StepLayout(title: "DodoSubs'a Hoş Geldiniz",
                   message: "DodoSubs, PS5 oyunlarındaki İngilizce altyazıları ve oyun içi telefon mesajlarını okuyup TV'nizde canlı Türkçe gösterir. Kendi kolunuzla oynamaya devam edersiniz.") {
            Card(title: "You will need:") {
                Label("A PS5 on the same Wi-Fi network as this Mac", systemImage: "gamecontroller")
                Label("An LG TV with the CouchSubs TV app", systemImage: "tv")
                Label("A free second PlayStation Network account", systemImage: "person.2")
            }
        }
    }
}
