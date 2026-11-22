// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import SwiftUI

/// Tam ekran "Geçmiş & Arama" stüdyo çalışma alanı (hem ana kenar çubuğundan gömülü hem pencere olarak kullanılır).
struct HistoryWorkspaceView: View {
    enum OriginFilter: String, CaseIterable, Identifiable {
        case all = "Tümü"
        case pack = "Oyun Paketi"
        case engine = "Yapay Zeka"
        var id: Self { self }
    }

    @EnvironmentObject private var model: AppModel
    var onDismiss: (() -> Void)? = nil
    @State private var query = ""
    @State private var filter: OriginFilter = .all
    @State private var copiedAll = false
    @State private var confirmClear = false

    private var filteredEntries: [SubtitleHistory.Entry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.history.entries.filter { entry in
            switch filter {
            case .all: break
            case .pack: if entry.origin != .pack { return false }
            case .engine: if entry.origin != .engine { return false }
            }
            guard !q.isEmpty else { return true }
            return entry.translation.localizedCaseInsensitiveContains(q) || entry.source.localizedCaseInsensitiveContains(q)
        }
    }

    private var packCount: Int { model.history.entries.filter { $0.origin == .pack }.count }
    private var engineCount: Int { model.history.entries.count - packCount }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space("gap")) {
            HStack(alignment: .center, spacing: Theme.space("m")) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Geçmiş & Transkript").font(.csDisplay)
                    Text(verbatim: String(format: String(localized: "The last %lld translated lines are kept on this computer."),
                                          SubtitleHistory.defaultLimit))
                        .font(.csCallout)
                        .foregroundStyle(Color.csSecondary)
                }
                Spacer()
                HStack(spacing: Theme.space("s")) {
                    Button(copiedAll ? "Copied" : "Copy all") {
                        copy(SubtitleHistory.plainText(filteredEntries))
                        copiedAll = true
                    }
                    .buttonStyle(.secondary)
                    .disabled(filteredEntries.isEmpty)
                    .resetsAfterDelay($copiedAll)
                    Button("Clear") { confirmClear = true }
                        .buttonStyle(.danger)
                        .disabled(model.history.entries.isEmpty)
                    if let onDismiss {
                        Button("Done", action: onDismiss)
                            .buttonStyle(.primary)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }

            if !model.history.entries.isEmpty {
                // Özet istatistik + canlı arama + kaynak filtre çipleri
                HStack(spacing: Theme.space("m")) {
                    HStack(spacing: Theme.space("s")) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Color.csSecondary)
                        TextField("Türkçe veya İngilizce diyaloglarda ara…", text: $query)
                            .textFieldStyle(.plain)
                            .font(.csBody)
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color.csSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.space("m"))
                    .frame(height: Theme.size("buttonHeight"))
                    .background(Color.csSurface2.opacity(0.68), in: RoundedRectangle(cornerRadius: Theme.radius("control"), style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius("control"), style: .continuous)
                            .strokeBorder(Color.csBorder.opacity(0.75), lineWidth: 1)
                    )

                    HStack(spacing: 4) {
                        ForEach(OriginFilter.allCases) { item in
                            let selected = filter == item
                            Button {
                                withAnimation(.easeOut(duration: 0.14)) { filter = item }
                            } label: {
                                Text(verbatim: item.rawValue)
                                    .font(.csCaption.weight(selected ? .semibold : .medium))
                                    .foregroundStyle(selected ? Color.csOnAccent : Color.csSecondary)
                                    .padding(.horizontal, 11)
                                    .frame(height: 32)
                                    .background(selected ? Color.csAccent : Color.clear, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                    .background(Color.csSurface2.opacity(0.65), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.csBorder.opacity(0.65), lineWidth: 1))
                }

                HStack(spacing: Theme.space("s")) {
                    TelemetryChip(icon: "text.alignleft", label: "\(filteredEntries.count) / \(model.history.entries.count) satır")
                    if packCount > 0 {
                        let pct = Int((Double(packCount) / Double(max(1, model.history.entries.count)) * 100).rounded())
                        TelemetryChip(icon: "shippingbox.fill", label: "Paket: \(packCount) (%\(pct))", tint: .csPro, softFill: .csProSoft)
                    }
                    if engineCount > 0 {
                        TelemetryChip(icon: "sparkles", label: "Motor: \(engineCount)", tint: .csAccentText, softFill: .csAccentSoft)
                    }
                    Spacer()
                }
            }

            if model.history.entries.isEmpty {
                VStack(spacing: Theme.space("m")) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(Color.csSecondary)
                        .frame(width: 64, height: 64)
                        .background(Color.csSurface2.opacity(0.75), in: Circle())
                    HintText(text: "No subtitles yet. Lines translated in this and earlier sessions appear here.")
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tile()
            } else if filteredEntries.isEmpty {
                VStack(spacing: Theme.space("s")) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.csSecondary)
                    Text("Filtre veya aramanızla eşleşen satır bulunamadı.")
                        .font(.csCallout)
                        .foregroundStyle(Color.csSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tile()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().overlay(Color.csBorder.opacity(0.55)) }
                            HistoryEntryRow(entry: entry)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tile()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog("Clear the history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { model.clearHistory() }
        } message: {
            Text("All saved lines are removed from this computer.")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Modal sayfa sarmalayıcısı (eski çağrılarla tam uyumlu).
struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HistoryWorkspaceView(onDismiss: { dismiss() })
            .padding(Theme.space("screen"))
            .frame(width: 720, height: Theme.size("windowHeight") - 2 * Theme.space("screen"))
    }
}

/// Bir satır: saat ve kaynak rozeti üstte, Türkçe, altında İngilizcesi; sağda kopyala.
private struct HistoryEntryRow: View {
    let entry: SubtitleHistory.Entry
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.space("m")) {
            VStack(alignment: .leading, spacing: Theme.space("hair")) {
                HStack(spacing: 6) {
                    Text(verbatim: entry.date.formatted(date: .omitted, time: .standard))
                        .font(.csCaption.monospacedDigit())
                        .foregroundStyle(Color.csSecondary)
                    Text(verbatim: origin)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(entry.origin == .pack ? Color.csPro : Color.csAccentText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            (entry.origin == .pack ? Color.csProSoft : Color.csAccentSoft).opacity(0.85),
                            in: Capsule()
                        )
                }
                Text(verbatim: entry.translation)
                    .font(.csBody.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: entry.source)
                    .font(.csCaption)
                    .foregroundStyle(Color.csSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(entry.translation)\n\(entry.source)", forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? Color.csSuccess : Color.csSecondary)
            }
            .buttonStyle(.borderless)
            .help(Text(copied ? "Copied" : "Copy"))
            .accessibilityLabel(Text("Copy"))
            .resetsAfterDelay($copied)
        }
        .padding(.vertical, Theme.space("m"))
    }

    private var origin: String {
        entry.origin == .pack ? String(localized: "Pack") : String(localized: "Translation engine")
    }
}
