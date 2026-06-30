/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct HeaderView: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))

                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
    }
}

struct CommandBlock: View {
    let title: String
    let command: String
    var copyEnabled = true

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title)
                        .font(.headline)

                    Spacer()

                    Button {
                        Clipboard.copy(command)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(!copyEnabled)
                }

                Text(command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

struct LogTextView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct EventLogGroup: View {
    let text: String
    var height: CGFloat? = nil
    var minHeight: CGFloat? = nil
    let eraseAction: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Event Log")
                        .font(.headline)

                    Spacer()

                    Button(action: eraseAction) {
                        Label("Erase", systemImage: "trash")
                    }
                    .disabled(text.isEmpty)
                    .help("Erase event log")
                }

                LogTextView(text: text.isEmpty ? "No events." : text)
                    .frame(height: height)
                    .frame(minHeight: minHeight)
            }
            .padding(.vertical, 4)
        }
    }
}
