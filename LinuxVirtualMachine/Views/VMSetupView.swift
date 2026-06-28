/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct VMSetupView: View {
    @EnvironmentObject private var store: TetheringStore
    @State private var assetFolderLoadAlert: AssetFolderLoadAlert?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderView(title: "VM Setup", subtitle: store.statusMessage, systemImage: "server.rack")

                HStack(spacing: 8) {
                    Button {
                        store.startVirtualMachine()
                    } label: {
                        Label("Start VM", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canStartVirtualMachine)
                    .help("Start the VM")

                    Button {
                        store.stopVirtualMachine()
                    } label: {
                        Label("Stop VM", systemImage: "stop.fill")
                    }
                    .disabled(!store.canStopVirtualMachine)
                    .help("Stop the VM")

                    Spacer()
                }

                GroupBox("VM Asset Folder") {
                    HStack(spacing: 12) {
                        Label("Asset folder", systemImage: "folder")
                            .font(.headline)

                        Text(store.vmAssetFolderInitialURL?.path ?? "Not selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 16)

                        Button {
                            if let url = FilePicker.chooseDirectory(
                                title: "Choose VM asset folder",
                                initialURL: store.vmAssetFolderInitialURL
                            ) {
                                if let error = store.loadVMAssets(from: url) {
                                    assetFolderLoadAlert = AssetFolderLoadAlert(message: error.localizedDescription)
                                }
                            }
                        } label: {
                            Label("Load Folder", systemImage: "folder.badge.gearshape")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Load individual files separately when you need to override the asset folder.") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 12) {
                            AssetPickerColumn(
                                title: "Linux kernel",
                                url: store.kernelURL,
                                systemImage: "doc"
                            ) {
                                if let url = FilePicker.chooseFile(title: "Choose Linux kernel", initialURL: store.kernelURL) {
                                    store.kernelURL = url
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            AssetPickerColumn(
                                title: "RTPVM initramfs",
                                url: store.initialRamdiskURL,
                                systemImage: "doc.zipper"
                            ) {
                                if let url = FilePicker.chooseFile(title: "Choose initial ramdisk", initialURL: store.initialRamdiskURL) {
                                    store.initialRamdiskURL = url
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            AssetPickerColumn(
                                title: "Optional scratch disk",
                                url: store.diskImageURL,
                                systemImage: "internaldrive",
                                action: {
                                    if let url = FilePicker.chooseFile(title: "Choose optional scratch disk image", initialURL: store.diskImageURL) {
                                        store.diskImageURL = url
                                    }
                                },
                                clearAction: {
                                    store.diskImageURL = nil
                                }
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Runtime") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 24) {
                            Stepper(value: $store.cpuCount, in: 1...8) {
                                LabeledContent("CPUs", value: "\(store.cpuCount)")
                            }
                            .frame(width: 180)

                            Stepper(
                                value: $store.memorySizeMiB,
                                in: store.memorySizeRangeMiB,
                                step: store.memorySizeStepMiB
                            ) {
                                LabeledContent("Memory", value: store.memorySizeLabel)
                            }
                            .frame(width: 210)
                        }

                        LabeledContent("Network") {
                            Text("VZNAT WireGuard peer + USB RNDIS upstream")
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Kernel arguments")
                                .font(.headline)

                            TextEditor(text: $store.kernelCommandLine)
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 72)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.vertical, 4)
                }

                EventLogGroup(text: store.eventLog, height: 160) {
                    store.clearEventLog()
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .navigationTitle("VM Setup")
        .alert(item: $assetFolderLoadAlert) { alert in
            Alert(
                title: Text("Invalid VM Asset Folder"),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

private struct AssetFolderLoadAlert: Identifiable {
    let id = UUID()
    let message: String
}

private struct AssetPickerColumn: View {
    let title: String
    let url: URL?
    let systemImage: String
    let action: () -> Void
    var clearAction: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .lineLimit(1)

            VStack(alignment: .leading, spacing: 3) {
                Text(url?.lastPathComponent ?? "Not selected")
                    .font(.caption)
                    .fontWeight(url == nil ? .regular : .semibold)
                    .foregroundStyle(url == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(url?.deletingLastPathComponent().path ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 6) {
                Button(action: action) {
                    Label("Choose", systemImage: "folder")
                }
                .controlSize(.small)

                if let clearAction, url != nil {
                    Button(action: clearAction) {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Clear")
                }

                Spacer(minLength: 0)
            }
        }
    }
}
