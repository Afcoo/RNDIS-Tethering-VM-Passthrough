/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: TetheringStore
    @State private var selection: AppSection? = .usb

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            DetailContainer(section: selection ?? .usb)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.startVirtualMachine()
                } label: {
                    Label("Start VM", systemImage: "play.fill")
                }
                .disabled(!store.canStartVirtualMachine)
                .help("Start the VM")

                Button {
                    store.stopVirtualMachine()
                } label: {
                    Label("Stop VM", systemImage: "stop.fill")
                }
                .disabled(!store.canStopVirtualMachine)
                .help("Stop the VM")
            }
        }
    }
}

private struct SidebarView: View {
    @Binding var selection: AppSection?

    var body: some View {
        List(AppSection.allCases, selection: $selection) { section in
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title)
                        .lineLimit(1)

                    Text(section.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .tag(section)
        }
        .listStyle(.sidebar)
        .navigationTitle("RTPVM")
    }
}

private struct DetailContainer: View {
    let section: AppSection

    var body: some View {
        switch section {
        case .setup:
            VMSetupView()
        case .usb:
            USBDevicesView()
        case .console:
            ConsoleView()
        case .vpn:
            WireguardView()
        }
    }
}
