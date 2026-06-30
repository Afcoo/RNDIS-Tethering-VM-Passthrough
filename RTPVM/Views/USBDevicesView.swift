/*
Copyright (C) 2026 Afcoo.
*/

import SwiftUI

struct USBDevicesView: View {
    @EnvironmentObject private var store: TetheringStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderView(
                title: "USB Devices",
                subtitle: "Select a USB tethering device to passthrough to the VM.",
                systemImage: "cable.connector"
            )

            if !store.runtimeEntitlements.accessoryAccessUSB {
                EntitlementNotice(
                    entitlement: RuntimeEntitlement.accessoryAccessUSB.rawValue,
                    message: "This local build is signed without the AccessoryAccess USB entitlement, so the USB listener is intentionally not registered."
                )
            }

            HStack {
                Button {
                    if store.isAccessoryMonitoring {
                        store.stopAccessoryMonitoring()
                    } else {
                        store.startAccessoryMonitoring()
                    }
                } label: {
                    Label(
                        store.isAccessoryMonitoring ? "Stop Listening" : "Listen",
                        systemImage: store.isAccessoryMonitoring ? "stop.circle" : "dot.radiowaves.left.and.right"
                    )
                }
                .disabled(!store.canStartAccessoryMonitoring && !store.canStopAccessoryMonitoring)

                Button {
                    store.attachSelectedAccessory()
                } label: {
                    Label("Attach", systemImage: "plus.circle")
                }
                .disabled(!store.canAttachSelectedAccessory)

                Button {
                    store.detachAccessory()
                } label: {
                    Label("Detach", systemImage: "minus.circle")
                }
                .disabled(!store.canDetachAccessory)

                Spacer()
            }

            if store.accessories.isEmpty {
                ContentUnavailableView("No USB accessories", systemImage: "cable.connector.slash")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $store.selectedAccessoryID) {
                    ForEach(store.accessories) { accessory in
                        USBAccessoryRow(
                            accessory: accessory,
                            isAttached: accessory.id == store.attachedAccessoryID
                        )
                        .tag(accessory.id)
                    }
                }
                .frame(minHeight: 280)
            }

            EventLogGroup(text: store.eventLog, minHeight: 130) {
                store.clearEventLog()
            }
        }
        .padding(20)
        .navigationTitle("USB Devices")
    }
}

struct EntitlementNotice: View {
    let entitlement: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                Text(entitlement)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct USBAccessoryRow: View {
    let accessory: USBAccessoryRecord
    let isAttached: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isAttached ? "checkmark.circle.fill" : "cable.connector")
                .foregroundStyle(isAttached ? .green : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(accessory.usbIDText)
                    .font(.headline)

                Text("Class \(accessory.classText)  Registry \(accessory.registryIDText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isAttached {
                Text("Attached")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
