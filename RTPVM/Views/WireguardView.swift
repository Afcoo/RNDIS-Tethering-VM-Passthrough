/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct WireguardView: View {
    @EnvironmentObject private var store: TetheringStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderView(title: "WireGuard", subtitle: store.wireGuardStatusMessage, systemImage: "lock.shield")

                GroupBox("Host Configuration") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(store.wireGuardHostConfiguration)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))

                        HStack {
                            Button {
                                store.copyWireGuardConfiguration()
                            } label: {
                                Label("Copy Config", systemImage: "doc.on.doc")
                            }
                            .disabled(!store.canExportWireGuardConfiguration)

                            Button {
                                store.saveWireGuardConfiguration()
                            } label: {
                                Label("Save .conf", systemImage: "square.and.arrow.down")
                            }
                            .disabled(!store.canExportWireGuardConfiguration)

                            Button {
                                store.reloadWireGuardConfiguration()
                            } label: {
                                Label("Reload Config", systemImage: "arrow.clockwise")
                            }

                            Button {
                                store.clearWireGuardEndpoint()
                            } label: {
                                Label("Clear Endpoint", systemImage: "xmark.circle")
                            }
                            .disabled(!store.canExportWireGuardConfiguration)

                            Spacer()
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .navigationTitle("WireGuard")
    }
}
