/*
Copyright (C) 2026 Afcoo.
*/

import AccessoryAccess
import Foundation
@preconcurrency import Virtualization

private enum USBPassthroughPolicy {
    static let attachFailureSuppressionInterval: TimeInterval = 10
    static let manualDetachAccessoryEventGraceInterval: TimeInterval = 10
}

@MainActor
final class USBAccessoryCoordinator {
    var onStateChange: (() -> Void)?
    var onStatusMessage: ((String) -> Void)?
    var onEvent: ((String) -> Void)?
    var onUnexpectedDetach: ((String) -> Void)?
    var virtualMachineProvider: (() -> VZVirtualMachine?)?
    var runtimeStateProvider: (() -> VMRuntimeState)?

    private let monitor = USBAccessoryMonitor()
    private var accessoryObjects: [UInt64: AAUSBAccessory] = [:]
    private var attachedDevice: VZUSBPassthroughDevice?
    private var accessoryEventSequence = 0
    private var pendingAttachAccessoryID: UInt64?
    private var lastAccessoryEventByDescriptor: [String: (kind: String, date: Date)] = [:]
    private var lastAttachAttemptByDescriptor: [String: Date] = [:]
    private var autoAttachSuppressedUntilByDescriptor: [String: Date] = [:]
    private var manuallyDetachedDescriptorKeys: Set<String> = []
    private var manualDetachEventSuppressedUntilByDescriptor: [String: Date] = [:]
    private var manualDetachEventSuppressedUntilByRegistryID: [UInt64: Date] = [:]
    private var manualPassthroughDisconnectSuppressedUntil: Date?

    private(set) var accessories: [USBAccessoryRecord] = []
    private(set) var isAccessoryMonitoring = false
    private(set) var selectedAccessoryID: UInt64?
    private(set) var attachedAccessoryID: UInt64?

    init() {
        configureAccessoryMonitor()
    }

    var canStartMonitoring: Bool {
        !isAccessoryMonitoring
    }

    var canStopMonitoring: Bool {
        isAccessoryMonitoring
    }

    func canAttachSelectedAccessory(runtimeState: VMRuntimeState) -> Bool {
        guard runtimeState == .running,
              let selectedAccessoryRecord,
              selectedAccessoryRecord.hasConfigurationDescriptor,
              accessoryObjects[selectedAccessoryRecord.id] != nil,
              attachedAccessoryID == nil,
              attachedDevice == nil,
              pendingAttachAccessoryID == nil else {
            return false
        }

        return attachSuppressionRemaining(for: selectedAccessoryRecord) == nil
    }

    func canDetachAccessory(runtimeState: VMRuntimeState) -> Bool {
        runtimeState == .running && attachedDevice != nil
    }

    func selectAccessory(id: UInt64?) {
        selectedAccessoryID = id
        notifyStateChanged()
    }

    func startMonitoring(reason: String) {
        guard !isAccessoryMonitoring else {
            onEvent?("USB listener already active: \(reason).")
            return
        }

        isAccessoryMonitoring = true
        notifyStateChanged()
        onEvent?("Registering AccessoryAccess USB listener: \(reason).")

        monitor.start { [weak self] result in
            Task { @MainActor in
                guard let self else { return }

                switch result {
                case .success(let connectedAccessories):
                    guard self.isAccessoryMonitoring else {
                        self.monitor.stop()
                        self.onEvent?("USB listener registration ignored because listener was stopped.")
                        return
                    }

                    connectedAccessories.forEach { self.addAccessory($0) }
                    self.onStatusMessage?("USB listener registered.")
                    self.onEvent?("USB listener registered with \(connectedAccessories.count) existing device(s).")
                    self.notifyStateChanged()
                case .failure(let error):
                    self.isAccessoryMonitoring = false
                    self.onStatusMessage?(error.localizedDescription)
                    self.onEvent?("USB listener failed: \(error.localizedDescription)")
                    self.notifyStateChanged()
                }
            }
        }
    }

    func stopMonitoring(reason: String) {
        guard isAccessoryMonitoring || !accessoryObjects.isEmpty || !accessories.isEmpty else {
            return
        }

        isAccessoryMonitoring = false
        accessoryObjects.removeAll()
        accessories.removeAll()
        selectedAccessoryID = nil
        pendingAttachAccessoryID = nil
        manuallyDetachedDescriptorKeys.removeAll()
        manualDetachEventSuppressedUntilByDescriptor.removeAll()
        manualDetachEventSuppressedUntilByRegistryID.removeAll()
        manualPassthroughDisconnectSuppressedUntil = nil
        notifyStateChanged()

        monitor.stop { [weak self] in
            Task { @MainActor in
                self?.onEvent?("AccessoryAccess USB listener stopped: \(reason)")
            }
        }
    }

    func resetForVMStart() {
        attachedAccessoryID = nil
        attachedDevice = nil
        pendingAttachAccessoryID = nil
        lastAttachAttemptByDescriptor.removeAll()
        autoAttachSuppressedUntilByDescriptor.removeAll()
        manuallyDetachedDescriptorKeys.removeAll()
        manualDetachEventSuppressedUntilByDescriptor.removeAll()
        manualDetachEventSuppressedUntilByRegistryID.removeAll()
        manualPassthroughDisconnectSuppressedUntil = nil
        notifyStateChanged()
    }

    func clearAttachmentForStoppedVM() {
        attachedAccessoryID = nil
        attachedDevice = nil
        pendingAttachAccessoryID = nil
        notifyStateChanged()
    }

    func prepareForVMRestartAfterUSBDetach() {
        attachedAccessoryID = nil
        attachedDevice = nil
        pendingAttachAccessoryID = nil
        notifyStateChanged()
    }

    func attachSelectedAccessory(to virtualMachine: VZVirtualMachine?) {
        guard let virtualMachine else {
            onStatusMessage?("Start the VM before attaching USB.")
            return
        }
        guard let selectedAccessoryID, let accessory = accessoryObjects[selectedAccessoryID] else {
            onStatusMessage?("Select a USB accessory.")
            return
        }

        let record = USBAccessoryRecord(accessory: accessory)
        guard record.hasConfigurationDescriptor else {
            onStatusMessage?("USB descriptor is incomplete.")
            onEvent?("USB attach not started for registry \(record.registryIDText): AccessoryAccess reported no configuration descriptor. Reconnect the device after enabling USB tethering, then attach when the configuration and interfaces appear.")
            return
        }

        if let remaining = attachSuppressionRemaining(for: record) {
            onStatusMessage?("USB attach cooling down.")
            onEvent?("USB attach not started for registry \(record.registryIDText): retry allowed in \(Self.secondsText(remaining)).")
            return
        }

        manuallyDetachedDescriptorKeys.remove(record.descriptorIdentityKey)
        manualDetachEventSuppressedUntilByDescriptor.removeValue(forKey: record.descriptorIdentityKey)
        manualDetachEventSuppressedUntilByRegistryID.removeValue(forKey: selectedAccessoryID)
        attach(accessory, record: record, to: virtualMachine, reason: "manual request")
    }

    func detachAccessory(from virtualMachine: VZVirtualMachine?) {
        guard let virtualMachine, let device = attachedDevice else {
            return
        }

        guard let controller = virtualMachine.usbControllers.first else {
            return
        }

        let detachedAccessoryID = attachedAccessoryID
        let detachedRecord = detachedAccessoryID.flatMap { id in
            accessories.first { $0.id == id }
        }

        if let detachedRecord {
            noteManualDetach(for: detachedRecord)
        }
        manualPassthroughDisconnectSuppressedUntil = Date().addingTimeInterval(USBPassthroughPolicy.manualDetachAccessoryEventGraceInterval)
        notifyStateChanged()

        controller.detach(device: device) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    if let detachedRecord {
                        self.manuallyDetachedDescriptorKeys.remove(detachedRecord.descriptorIdentityKey)
                        self.manualDetachEventSuppressedUntilByDescriptor.removeValue(forKey: detachedRecord.descriptorIdentityKey)
                        self.manualDetachEventSuppressedUntilByRegistryID.removeValue(forKey: detachedRecord.id)
                    }
                    self.manualPassthroughDisconnectSuppressedUntil = nil
                    self.onStatusMessage?(error.localizedDescription)
                    self.onEvent?("USB detach failed: \(error.localizedDescription)")
                } else {
                    self.attachedAccessoryID = nil
                    self.attachedDevice = nil
                    self.onStatusMessage?("USB accessory detached from VM.")
                    self.onEvent?("USB accessory detached from VM by user.")
                }
                self.notifyStateChanged()
            }
        }
    }

    func handlePassthroughDisconnect() {
        let attachedRegistry = attachedAccessoryID.map(Self.registryIDText) ?? "none"
        if isManualPassthroughDisconnectSuppressed() {
            attachedAccessoryID = nil
            attachedDevice = nil
            notifyStateChanged()
            onEvent?("USB passthrough disconnect ignored because it was produced by a manual VM detach, attached registry \(attachedRegistry).")
            return
        }

        attachedAccessoryID = nil
        attachedDevice = nil
        notifyStateChanged()
        onEvent?("USB passthrough device disconnected by the system, attached registry \(attachedRegistry).")
        onUnexpectedDetach?("Virtualization USB passthrough disconnect for registry \(attachedRegistry)")
    }

    private var selectedAccessoryRecord: USBAccessoryRecord? {
        guard let selectedAccessoryID else { return nil }
        return accessories.first { $0.id == selectedAccessoryID }
    }

    private func configureAccessoryMonitor() {
        monitor.onConnect = { [weak self] accessory in
            Task { @MainActor in
                self?.addAccessory(accessory)
            }
        }

        monitor.onDisconnect = { [weak self] accessory in
            Task { @MainActor in
                self?.removeAccessory(accessory)
            }
        }
    }

    private func attach(_ accessory: AAUSBAccessory, record: USBAccessoryRecord, to virtualMachine: VZVirtualMachine, reason: String) {
        let registryID = accessory.registryID
        let descriptorKey = record.descriptorIdentityKey
        guard attachedAccessoryID == nil, attachedDevice == nil else {
            let attachedRegistry = attachedAccessoryID.map(Self.registryIDText) ?? "unknown"
            onStatusMessage?("Only one USB passthrough accessory is supported per VM session.")
            onEvent?("USB attach skipped for registry \(record.registryIDText): single passthrough device limit is already active with registry \(attachedRegistry).")
            return
        }

        guard pendingAttachAccessoryID == nil else {
            onEvent?("USB attach skipped for registry \(record.registryIDText): attach already pending for \(Self.registryIDText(pendingAttachAccessoryID!)).")
            return
        }

        pendingAttachAccessoryID = registryID
        lastAttachAttemptByDescriptor[descriptorKey] = Date()
        notifyStateChanged()
        onEvent?("USB attach requested: \(record.descriptorDiagnosticText), registry \(record.registryIDText), reason=\(reason), vm=\(currentRuntimeState.rawValue), usbControllers=\(virtualMachine.usbControllers.count).")

        do {
            let configuration = VZUSBPassthroughDeviceConfiguration(device: accessory)
            let device = try VZUSBPassthroughDevice(configuration: configuration)

            guard let controller = virtualMachine.usbControllers.first else {
                pendingAttachAccessoryID = nil
                notifyStateChanged()
                onStatusMessage?("VM has no USB controller.")
                onEvent?("USB attach failed: VM has no USB controller for registry \(record.registryIDText).")
                return
            }

            controller.attach(device: device) { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }

                    guard self.pendingAttachAccessoryID == registryID else {
                        self.onEvent?("USB attach completion ignored for registry \(record.registryIDText): attach is no longer current.")
                        return
                    }

                    self.pendingAttachAccessoryID = nil

                    if let error {
                        self.onStatusMessage?(error.localizedDescription)
                        self.onEvent?("USB attach failed: \(error.localizedDescription)")
                        self.suppressAutoAttach(
                            for: record,
                            interval: USBPassthroughPolicy.attachFailureSuppressionInterval,
                            reason: "VZ USB controller attach failed: \(error.localizedDescription)"
                        )
                    } else {
                        self.attachedAccessoryID = registryID
                        self.attachedDevice = device
                        self.onStatusMessage?("USB accessory attached.")
                        self.onEvent?("USB accessory attached: registry \(record.registryIDText).")
                    }
                    self.notifyStateChanged()
                }
            }
        } catch {
            pendingAttachAccessoryID = nil
            notifyStateChanged()
            onStatusMessage?(error.localizedDescription)
            onEvent?("USB passthrough device creation failed for registry \(record.registryIDText): \(error.localizedDescription)")
            suppressAutoAttach(
                for: record,
                interval: USBPassthroughPolicy.attachFailureSuppressionInterval,
                reason: "VZ passthrough device creation failed: \(error.localizedDescription)"
            )
        }
    }

    private func addAccessory(_ accessory: AAUSBAccessory) {
        accessoryObjects[accessory.registryID] = accessory
        let record = USBAccessoryRecord(accessory: accessory)
        let replacedSelectedRecord = accessories.contains { existingRecord in
            existingRecord.descriptorIdentityKey == record.descriptorIdentityKey
                && selectedAccessoryID == existingRecord.id
        }

        if manuallyDetachedDescriptorKeys.contains(record.descriptorIdentityKey) {
            accessories.removeAll { $0.id == record.id || $0.descriptorIdentityKey == record.descriptorIdentityKey }
        } else {
            accessories.removeAll { $0.id == record.id }
        }

        accessories.append(record)
        accessories.sort { $0.usbIDText < $1.usbIDText }
        if selectedAccessoryID == nil || replacedSelectedRecord {
            selectedAccessoryID = record.id
        }
        notifyStateChanged()
        onEvent?("USB connected: \(record.descriptorDiagnosticText), registry \(record.registryIDText), \(accessoryEventContext(for: record, kind: "connect")).")
        autoAttachIfPossible(accessory, record: record)
    }

    private func removeAccessory(_ accessory: AAUSBAccessory) {
        let record = USBAccessoryRecord(accessory: accessory)
        let wasSelected = selectedAccessoryID == accessory.registryID
        let wasAttached = attachedAccessoryID == accessory.registryID

        if manualDetachEventSuppressionRemaining(for: record) != nil {
            accessoryObjects[accessory.registryID] = nil
            notifyStateChanged()
            onEvent?("USB AccessoryAccess disconnect ignored during manual VM detach: registry \(record.registryIDText), \(accessoryEventContext(for: record, kind: "disconnect")).")
            return
        }

        accessoryObjects[accessory.registryID] = nil
        accessories.removeAll { $0.id == accessory.registryID }

        if wasSelected {
            selectedAccessoryID = accessories.first?.id
        }

        if wasAttached {
            attachedAccessoryID = nil
            attachedDevice = nil
        }

        if pendingAttachAccessoryID == accessory.registryID {
            pendingAttachAccessoryID = nil
            suppressAutoAttach(
                for: record,
                interval: USBPassthroughPolicy.attachFailureSuppressionInterval,
                reason: "device disconnected while VZ attach was pending."
            )
            onEvent?("USB disconnected while VZ attach was pending for registry \(record.registryIDText).")
        }

        notifyStateChanged()
        onEvent?("USB disconnected: \(record.descriptorDiagnosticText), registry \(record.registryIDText), wasSelected=\(wasSelected), wasAttached=\(wasAttached), \(accessoryEventContext(for: record, kind: "disconnect")).")

        if wasAttached {
            onEvent?("USB disconnect matched the attached passthrough accessory; restarting VM to recreate a fixed usb0 session.")
            onUnexpectedDetach?("AccessoryAccess disconnect for attached registry \(record.registryIDText)")
        }
    }

    private func autoAttachIfPossible(_ accessory: AAUSBAccessory, record: USBAccessoryRecord) {
        guard currentRuntimeState == .running, let virtualMachine = virtualMachineProvider?() else {
            return
        }

        guard attachedAccessoryID == nil, attachedDevice == nil, pendingAttachAccessoryID == nil else {
            onEvent?("USB auto-attach skipped for registry \(record.registryIDText): single passthrough device limit is already active.")
            return
        }

        guard record.hasConfigurationDescriptor else {
            onEvent?("USB auto-attach skipped for registry \(record.registryIDText): AccessoryAccess reported no configuration descriptor. Select the device and attach manually only after it stabilizes.")
            return
        }

        guard !isManualDetachedAutoAttachBlocked(for: record) else {
            return
        }

        guard !isAutoAttachSuppressed(for: record) else {
            return
        }

        onEvent?("USB auto-attach on connect: registry \(record.registryIDText).")
        attach(accessory, record: record, to: virtualMachine, reason: "auto connect")
    }

    private func noteManualDetach(for record: USBAccessoryRecord) {
        let suppressedUntil = Date().addingTimeInterval(USBPassthroughPolicy.manualDetachAccessoryEventGraceInterval)
        manuallyDetachedDescriptorKeys.insert(record.descriptorIdentityKey)
        manualDetachEventSuppressedUntilByDescriptor[record.descriptorIdentityKey] = suppressedUntil
        manualDetachEventSuppressedUntilByRegistryID[record.id] = suppressedUntil
        onEvent?("USB manual detach policy: keeping \(record.registryIDText) in the device list and blocking automatic reattach until the next manual attach.")
    }

    private func isManualDetachedAutoAttachBlocked(for record: USBAccessoryRecord) -> Bool {
        guard manuallyDetachedDescriptorKeys.contains(record.descriptorIdentityKey) else {
            return false
        }

        onEvent?("USB auto-attach skipped for registry \(record.registryIDText): device was manually detached from the VM.")
        return true
    }

    private func isAutoAttachSuppressed(for record: USBAccessoryRecord) -> Bool {
        guard let remaining = attachSuppressionRemaining(for: record) else { return false }

        onEvent?("USB auto-attach suppressed for registry \(record.registryIDText): retry allowed in \(Self.secondsText(remaining)).")
        return true
    }

    private func attachSuppressionRemaining(for record: USBAccessoryRecord) -> TimeInterval? {
        guard let suppressedUntil = autoAttachSuppressedUntilByDescriptor[record.descriptorIdentityKey] else {
            return nil
        }

        let now = Date()
        guard suppressedUntil > now else {
            autoAttachSuppressedUntilByDescriptor[record.descriptorIdentityKey] = nil
            return nil
        }

        return suppressedUntil.timeIntervalSince(now)
    }

    private func suppressAutoAttach(for record: USBAccessoryRecord, interval: TimeInterval, reason: String) {
        let suppressedUntil = Date().addingTimeInterval(interval)
        autoAttachSuppressedUntilByDescriptor[record.descriptorIdentityKey] = suppressedUntil
        onEvent?("USB auto-attach suppressed for descriptor \(record.usbIDText) for \(Self.secondsText(interval)): \(reason)")
    }

    private func manualDetachEventSuppressionRemaining(for record: USBAccessoryRecord) -> TimeInterval? {
        if let remaining = suppressionRemaining(
            until: manualDetachEventSuppressedUntilByDescriptor[record.descriptorIdentityKey],
            onExpired: {
                manualDetachEventSuppressedUntilByDescriptor[record.descriptorIdentityKey] = nil
            }
        ) {
            return remaining
        }

        return suppressionRemaining(
            until: manualDetachEventSuppressedUntilByRegistryID[record.id],
            onExpired: {
                manualDetachEventSuppressedUntilByRegistryID[record.id] = nil
            }
        )
    }

    private func suppressionRemaining(until suppressedUntil: Date?, onExpired: () -> Void) -> TimeInterval? {
        guard let suppressedUntil else {
            return nil
        }

        let now = Date()
        guard suppressedUntil > now else {
            onExpired()
            return nil
        }

        return suppressedUntil.timeIntervalSince(now)
    }

    private func isManualPassthroughDisconnectSuppressed() -> Bool {
        guard let suppressedUntil = manualPassthroughDisconnectSuppressedUntil else {
            return false
        }

        let now = Date()
        guard suppressedUntil > now else {
            manualPassthroughDisconnectSuppressedUntil = nil
            return false
        }

        return true
    }

    private func accessoryEventContext(for record: USBAccessoryRecord, kind: String) -> String {
        accessoryEventSequence += 1

        let now = Date()
        let previousEvent = lastAccessoryEventByDescriptor[record.descriptorIdentityKey]
        lastAccessoryEventByDescriptor[record.descriptorIdentityKey] = (kind: kind, date: now)

        var components = [
            "event #\(accessoryEventSequence)",
            "vm=\(currentRuntimeState.rawValue)"
        ]

        if let previousEvent {
            let interval = now.timeIntervalSince(previousEvent.date)
            components.append(String(format: "%.2fs after previous %@ for same descriptor", interval, previousEvent.kind))
        } else {
            components.append("first event for descriptor")
        }

        if let selectedAccessoryID {
            components.append("selected=\(Self.registryIDText(selectedAccessoryID))")
        } else {
            components.append("selected=none")
        }

        if let attachedAccessoryID {
            components.append("attached=\(Self.registryIDText(attachedAccessoryID))")
        } else {
            components.append("attached=none")
        }

        return components.joined(separator: ", ")
    }

    private var currentRuntimeState: VMRuntimeState {
        runtimeStateProvider?() ?? .idle
    }

    private func notifyStateChanged() {
        onStateChange?()
    }

    private static func registryIDText(_ registryID: UInt64) -> String {
        "0x" + String(registryID, radix: 16, uppercase: true)
    }

    private static func secondsText(_ interval: TimeInterval) -> String {
        String(format: "%.1fs", max(0, interval))
    }
}
