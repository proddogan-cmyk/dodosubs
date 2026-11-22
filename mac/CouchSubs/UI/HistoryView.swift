// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import SwiftUI

/// "Geçmiş": bu ve önceki oturumlarda çevrilen son satırlar (en yenisi üstte); canlı arama ve tek tık kopyalama.
struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var copiedAll = false
    @State private var confirmClear = false

    private var filteredEntries: [SubtitleHistory.Entry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return model.history.entries }
        return model.history.entries.filter {
            $0.translation.localizedCaseInsensitiveContains(q) || $0.source.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space("gap")) {
            HStack(alignment: .firstTextBaseline) {
                Text("History").font(.csDisplay)
                Spacer()
                if !model.history.entries.isEmpty {
                    let countText = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "\(model.history.entries.count) satır"
                        : "\(filteredEntries.count) / \(model.history.entries.count) eşleşme"
                    Pill(text: countText, tone: .muted)
                }
            }
            HintText(text: LocalizedStringKey(String(format: String(localized: "The last %lld translated lines are kept on this computer."),
                                                     SubtitleHistory.defaultLimit)))
            if !model.history.entries.isEmpty {
                HStack(spacing: Theme.space("s")) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.csSecondary)
                    TextField("Türkçe veya İngilizce satırlarda ara…", text: $query)
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
                .background(Color.csSurface2.opacity(0.72), in: RoundedRectangle(cornerRadius: Theme.radius("control"), style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius("control"), style: .continuous)
                        .strokeBorder(Color.csBorder.opacity(0.8), lineWidth: 1)
                )
            }
            if model.history.entries.isEmpty {
                Spacer()
                HintText(text: "No subtitles yet. Lines translated in this and earlier sessions appear here.")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if filteredEntries.isEmpty {
                Spacer()
                Text("Aramanızla eşleşen altyazı bulunamadı.")
                    .font(.csCallout)
                    .foregroundStyle(Color.csSecondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().overlay(Color.csBorder.opacity(0.65)) }
                            HistoryEntryRow(entry: entry)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tile()
            }
            // Alttaki düğmeler aynı yükseklikte (`buttonLarge`).
            HStack(spacing: Theme.space("m")) {
                Button(copiedAll ? "Copied" : "Copy all") {
                    copy(SubtitleHistory.plainText(filteredEntries))
                    copiedAll = true
                }
                .buttonStyle(CSButtonStyle(kind: .secondary, height: "buttonLarge"))
                .disabled(filteredEntries.isEmpty)
                .resetsAfterDelay($copiedAll)
                Button("Clear") { confirmClear = true }
                    .buttonStyle(CSButtonStyle(kind: .danger, height: "buttonLarge"))
                    .disabled(model.history.entries.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(CSButtonStyle(kind: .primary, height: "buttonLarge"))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.space("screen"))
        .frame(width: 680, height: Theme.size("windowHeight") - 2 * Theme.space("screen"))
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
