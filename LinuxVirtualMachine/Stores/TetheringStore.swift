/*
Copyright (C) 2026 Afcoo.
*/

import AccessoryAccess
import Darwin
import Foundation
@preconcurrency import Virtualization

private enum AlpineBootDefaults {
    static let initramfsModules = "virtio_pci,virtio_mmio,virtio_console"
    static let initramfsKernelCommandLine = "console=hvc0 rdinit=/sbin/init modules=\(initramfsModules)"
}

private enum USBPassthroughPolicy {
    static let attachFailureSuppressionInterval: TimeInterval = 10
    static let manualDetachAccessoryEventGraceInterval: TimeInterval = 10
}

private enum VMMemoryDefaults {
    static let minimumMiB = 256
    static let maximumMiB = 16 * 1024
    static let defaultMiB = 1024
    static let stepMiB = 256
}

private struct VMAssetFolderSelection {
    let kernelURL: URL
    let initialRamdiskURL: URL
}

private enum VMAssetFolderLoadError: LocalizedError {
    case notDirectory(URL)
    case missingKernel(URL)
    case missingInitramfs(URL)

    var errorDescription: String? {
        switch self {
        case .notDirectory(let url):
            return "Selected VM asset path is not a folder: \(url.path)"
        case .missingKernel(let url):
            return "No Image-* kernel found in VM asset folder: \(url.path)"
        case .missingInitramfs(let url):
            return "No initramfs-rtpvm-* ramdisk found in VM asset folder: \(url.path)"
        }
    }
}

@MainActor
final class TetheringStore: ObservableObject {
    @Published var kernelURL: URL? {
        didSet {
            persistFileURL(kernelURL, forKey: DefaultsKey.kernelURLPath)
            reloadWireGuardConfigurationFromAssets(reason: "kernel selection changed")
        }
    }
    @Published var initialRamdiskURL: URL? {
        didSet {
            persistFileURL(initialRamdiskURL, forKey: DefaultsKey.initialRamdiskURLPath)
            reloadWireGuardConfigurationFromAssets(reason: "initramfs selection changed")
        }
    }
    @Published var diskImageURL: URL? {
        didSet { persistFileURL(diskImageURL, forKey: DefaultsKey.diskImageURLPath) }
    }
    @Published var cpuCount = 1
    @Published var memorySizeMiB = VMMemoryDefaults.defaultMiB
    @Published var kernelCommandLine = AlpineBootDefaults.initramfsKernelCommandLine

    @Published private(set) var runtimeState: VMRuntimeState = .idle
    @Published private(set) var statusMessage = "Select Alpine VM assets to begin."
    @Published private(set) var runtimeEntitlements = RuntimeEntitlementSnapshot.current
    @Published private(set) var accessories: [USBAccessoryRecord] = []
    @Published private(set) var isAccessoryMonitoring = false
    @Published var selectedAccessoryID: UInt64?
    @Published private(set) var attachedAccessoryID: UInt64?
    @Published private(set) var consoleText = ""
    @Published private(set) var consoleOutputData = Data()
    @Published private(set) var consoleOutputSequence = 0
    @Published private(set) var consoleResetSequence = 0
    @Published private(set) var eventLog = ""
    @Published private(set) var wireGuardSettings: WireGuardSettings
    @Published private(set) var wireGuardStatusMessage = "Run the asset build script, select the generated assets, then start the VM to discover the endpoint."

    let guestMACAddress = "02:00:5E:10:00:02"

    private let monitor = AccessoryMonitor()
    private let wireGuardConfigurationLoader: WireGuardConfigurationLoader
    private var accessoryObjects: [UInt64: AAUSBAccessory] = [:]
    private var virtualMachine: VZVirtualMachine?
    private var vmDelegate: VirtualMachineDelegateBox?
    private var runtimeResources: VMRuntimeResources?
    private var attachedDevice: VZUSBPassthroughDevice?
    private var accessoryEventSequence = 0
    private var pendingAttachAccessoryID: UInt64?
    private var isRestartingAfterUSBDetach = false
    private var lastAccessoryEventByDescriptor: [String: (kind: String, date: Date)] = [:]
    private var lastAttachAttemptByDescriptor: [String: Date] = [:]
    private var autoAttachSuppressedUntilByDescriptor: [String: Date] = [:]
    private var manuallyDetachedDescriptorKeys: Set<String> = []
    private var manualDetachEventSuppressedUntilByDescriptor: [String: Date] = [:]
    private var manualPassthroughDisconnectSuppressedUntil: Date?
    private var hasReceivedConsoleOutput = false
    private var didRequestLaunchAccessoryMonitoring = false
    private var consoleOutputWatchdogTask: Task<Void, Never>?

    var canStartVirtualMachine: Bool {
        kernelURL != nil && initialRamdiskURL != nil && runtimeState != .starting && runtimeState != .running
    }

    var memorySizeRangeMiB: ClosedRange<Int> {
        VMMemoryDefaults.minimumMiB...VMMemoryDefaults.maximumMiB
    }

    var memorySizeStepMiB: Int {
        VMMemoryDefaults.stepMiB
    }

    var memorySizeLabel: String {
        guard memorySizeMiB >= 1024 else {
            return "\(memorySizeMiB) MiB"
        }

        let wholeGiB = memorySizeMiB / 1024
        let remainderMiB = memorySizeMiB % 1024

        switch remainderMiB {
        case 0:
            return "\(wholeGiB) GiB"
        case 256:
            return "\(wholeGiB).25 GiB"
        case 512:
            return "\(wholeGiB).5 GiB"
        case 768:
            return "\(wholeGiB).75 GiB"
        default:
            return "\(memorySizeMiB) MiB"
        }
    }

    var vmAssetFolderInitialURL: URL? {
        if let configuredVMAssetFolderURL {
            return configuredVMAssetFolderURL
        }
        if let diskImageURL {
            return vmAssetFolderURL(containing: diskImageURL)
        }

        return nil
    }

    private var configuredVMAssetFolderURL: URL? {
        if let initialRamdiskURL {
            return vmAssetFolderURL(containing: initialRamdiskURL)
        }
        if let kernelURL {
            return vmAssetFolderURL(containing: kernelURL)
        }

        return nil
    }

    var canStartAccessoryMonitoring: Bool {
        runtimeEntitlements.accessoryAccessUSB && !isAccessoryMonitoring
    }

    var canStopAccessoryMonitoring: Bool {
        isAccessoryMonitoring
    }

    var usbListenerSubtitle: String {
        if !runtimeEntitlements.accessoryAccessUSB {
            return "Missing AccessoryAccess USB entitlement in this local build."
        }

        return isAccessoryMonitoring ? "AccessoryAccess listener active." : "AccessoryAccess listener inactive."
    }

    var canStopVirtualMachine: Bool {
        runtimeState == .running || runtimeState == .starting
    }

    var canSendConsoleInput: Bool {
        runtimeState == .running && (runtimeResources?.consoleInputPipe.fileHandleForWriting.fileDescriptor ?? -1) >= 0
    }

    var canAttachSelectedAccessory: Bool {
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

    var canDetachAccessory: Bool {
        runtimeState == .running && attachedDevice != nil
    }

    private var selectedAccessoryRecord: USBAccessoryRecord? {
        guard let selectedAccessoryID else { return nil }
        return accessories.first { $0.id == selectedAccessoryID }
    }

    var canExportWireGuardConfiguration: Bool {
        wireGuardSettings.hasKeyMaterial && wireGuardSettings.endpoint != nil
    }

    var wireGuardHostConfiguration: String {
        wireGuardConfigurationLoader.hostConfiguration(settings: wireGuardSettings)
    }

    init() {
        let wireGuardConfigurationLoader = WireGuardConfigurationLoader()
        self.wireGuardConfigurationLoader = wireGuardConfigurationLoader
        self.wireGuardSettings = wireGuardConfigurationLoader.emptySettings()
        restoreAssetSelections()
        reloadWireGuardConfigurationFromAssets(reason: "restored asset selection")
        configureAccessoryMonitor()
        appendRuntimeEntitlementSummary()
        appendAssetSelectionSummaryIfNeeded()
    }

    deinit {
        monitor.stop()
        runtimeResources?.consoleOutputPipe.fileHandleForReading.readabilityHandler = nil
    }

    func startAccessoryMonitoring() {
        startAccessoryMonitoring(reason: "manual request")
    }

    func startAccessoryMonitoringOnLaunch() {
        guard !didRequestLaunchAccessoryMonitoring else {
            return
        }

        didRequestLaunchAccessoryMonitoring = true
        startAccessoryMonitoring(reason: "app launch")
    }

    @discardableResult
    func loadVMAssets(from directoryURL: URL) -> Error? {
        do {
            let selection = try resolveVMAssetFolder(directoryURL)
            kernelURL = selection.kernelURL
            initialRamdiskURL = selection.initialRamdiskURL
            statusMessage = "Loaded VM assets from folder."
            appendEvent("Loaded VM assets from folder: \(directoryURL.standardizedFileURL.path).")
            return nil
        } catch {
            statusMessage = error.localizedDescription
            appendEvent("VM asset folder load failed: \(error.localizedDescription)")
            return error
        }
    }

    private func startAccessoryMonitoring(reason: String) {
        refreshRuntimeEntitlements()

        guard runtimeEntitlements.accessoryAccessUSB else {
            reportMissingEntitlement(.accessoryAccessUSB, action: "USB listener")
            return
        }

        guard !isAccessoryMonitoring else {
            appendEvent("USB listener already active: \(reason).")
            return
        }

        isAccessoryMonitoring = true
        appendEvent("Registering AccessoryAccess USB listener: \(reason).")

        monitor.start { [weak self] result in
            Task { @MainActor in
                guard let self else { return }

                switch result {
                case .success(let connectedAccessories):
                    guard self.isAccessoryMonitoring else {
                        self.monitor.stop()
                        self.appendEvent("USB listener registration ignored because listener was stopped.")
                        return
                    }

                    connectedAccessories.forEach { self.addAccessory($0) }
                    self.statusMessage = "USB listener registered."
                    self.appendEvent("USB listener registered with \(connectedAccessories.count) existing device(s).")
                case .failure(let error):
                    self.isAccessoryMonitoring = false
                    self.statusMessage = error.localizedDescription
                    self.appendEvent("USB listener failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func stopAccessoryMonitoring() {
        stopAccessoryMonitoring(reason: "User stopped USB listener.")
    }

    func startVirtualMachine() {
        refreshRuntimeEntitlements()
        migrateLegacyInitramfsSelectionIfNeeded()
        reloadWireGuardConfigurationFromAssets(reason: "VM starting")

        guard runtimeEntitlements.virtualization else {
            reportMissingEntitlement(.virtualization, action: "VM start")
            return
        }

        guard let kernelURL, let initialRamdiskURL else {
            statusMessage = "Kernel and RTPVM initramfs are required."
            return
        }

        releaseRuntimeResources()
        cancelConsoleOutputWatchdog()
        clearWireGuardEndpoint(reason: "VM starting")
        consoleText = ""
        consoleOutputData = Data()
        consoleOutputSequence = 0
        consoleResetSequence &+= 1
        hasReceivedConsoleOutput = false
        attachedAccessoryID = nil
        attachedDevice = nil
        pendingAttachAccessoryID = nil
        lastAttachAttemptByDescriptor.removeAll()
        autoAttachSuppressedUntilByDescriptor.removeAll()
        manuallyDetachedDescriptorKeys.removeAll()
        manualDetachEventSuppressedUntilByDescriptor.removeAll()
        manualPassthroughDisconnectSuppressedUntil = nil

        do {
            let bootCommandLine = normalizedBootCommandLine()
            if bootCommandLine != kernelCommandLine {
                kernelCommandLine = bootCommandLine
                appendEvent("Adjusted kernel arguments for initramfs-only boot.")
            }

            let input = VMConfigurationInput(
                kernelURL: kernelURL,
                initialRamdiskURL: initialRamdiskURL,
                diskImageURL: diskImageURL,
                cpuCount: cpuCount,
                memorySizeBytes: UInt64(memorySizeMiB) * 1024 * 1024,
                bootCommandLine: bootCommandLine,
                guestMACAddress: guestMACAddress
            )

            let result = try VMConfigurationFactory.build(input: input)
            installConsoleReader(result.resources.consoleOutputPipe)

            let virtualMachine = VZVirtualMachine(configuration: result.configuration)
            let delegate = makeDelegate()
            virtualMachine.delegate = delegate
            virtualMachine.usbControllers.forEach { $0.delegate = delegate }

            self.virtualMachine = virtualMachine
            self.vmDelegate = delegate
            self.runtimeResources = result.resources
            self.runtimeState = .starting
            self.statusMessage = "Starting VM."
            appendEvent("Starting ephemeral Alpine RTPVM guest with NAT setup NIC, USB RNDIS upstream, and WireGuard peer support.")
            appendSelectedAssetDiagnostics(kernelURL: kernelURL, initialRamdiskURL: initialRamdiskURL)
            appendEvent("Kernel arguments: \(bootCommandLine)")

            virtualMachine.start { [weak self] startResult in
                Task { @MainActor in
                    guard let self else { return }

                    switch startResult {
                    case .success:
                        self.runtimeState = .running
                        self.statusMessage = "VM running."
                        self.appendEvent("VM started.")
                        self.scheduleConsoleOutputWatchdog()
                    case .failure(let error):
                        self.runtimeState = .failed
                        self.statusMessage = error.localizedDescription
                        self.appendEvent("VM start failed: \(error.localizedDescription)")
                        self.virtualMachine = nil
                        self.vmDelegate = nil
                        self.releaseRuntimeResources()
                    }
                }
            }
        } catch {
            runtimeState = .failed
            statusMessage = error.localizedDescription
            appendEvent("VM configuration failed: \(error.localizedDescription)")
        }
    }

    func stopVirtualMachine() {
        guard let virtualMachine else {
            return
        }

        runtimeState = .stopping
        statusMessage = "Stopping VM."
        appendEvent("Stopping VM.")

        virtualMachine.stop { [weak self] error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.runtimeState = .failed
                    self.statusMessage = error.localizedDescription
                    self.appendEvent("VM stop failed: \(error.localizedDescription)")
                } else {
                    self.markStopped(message: "VM stopped.")
                }
            }
        }
    }

    func attachSelectedAccessory() {
        refreshRuntimeEntitlements()

        guard runtimeEntitlements.accessoryAccessUSB else {
            reportMissingEntitlement(.accessoryAccessUSB, action: "USB attach")
            return
        }

        guard let virtualMachine else {
            statusMessage = "Start the VM before attaching USB."
            return
        }
        guard let selectedAccessoryID, let accessory = accessoryObjects[selectedAccessoryID] else {
            statusMessage = "Select a USB accessory."
            return
        }

        let record = USBAccessoryRecord(accessory: accessory)
        guard record.hasConfigurationDescriptor else {
            statusMessage = "USB descriptor is incomplete."
            appendEvent("USB attach not started for registry \(record.registryIDText): AccessoryAccess reported no configuration descriptor. Reconnect the device after enabling USB tethering, then attach when the configuration and interfaces appear.")
            return
        }

        if let remaining = attachSuppressionRemaining(for: record) {
            statusMessage = "USB attach cooling down."
            appendEvent("USB attach not started for registry \(record.registryIDText): retry allowed in \(Self.secondsText(remaining)).")
            return
        }

        manuallyDetachedDescriptorKeys.remove(record.descriptorIdentityKey)
        manualDetachEventSuppressedUntilByDescriptor.removeValue(forKey: record.descriptorIdentityKey)
        attach(accessory, record: record, to: virtualMachine, reason: "manual request")
    }

    private func attach(_ accessory: AAUSBAccessory, record: USBAccessoryRecord, to virtualMachine: VZVirtualMachine, reason: String) {
        let registryID = accessory.registryID
        let descriptorKey = record.descriptorIdentityKey
        guard attachedAccessoryID == nil, attachedDevice == nil else {
            let attachedRegistry = attachedAccessoryID.map(Self.registryIDText) ?? "unknown"
            statusMessage = "Only one USB passthrough accessory is supported per VM session."
            appendEvent("USB attach skipped for registry \(record.registryIDText): single passthrough device limit is already active with registry \(attachedRegistry).")
            return
        }

        guard pendingAttachAccessoryID == nil else {
            appendEvent("USB attach skipped for registry \(record.registryIDText): attach already pending for \(Self.registryIDText(pendingAttachAccessoryID!)).")
            return
        }

        pendingAttachAccessoryID = registryID
        lastAttachAttemptByDescriptor[descriptorKey] = Date()
        appendEvent("USB attach requested: \(record.descriptorDiagnosticText), registry \(record.registryIDText), reason=\(reason), vm=\(runtimeState.rawValue), usbControllers=\(virtualMachine.usbControllers.count).")

        do {
            let configuration = VZUSBPassthroughDeviceConfiguration(device: accessory)
            let device = try VZUSBPassthroughDevice(configuration: configuration)

            guard let controller = virtualMachine.usbControllers.first else {
                pendingAttachAccessoryID = nil
                statusMessage = "VM has no USB controller."
                appendEvent("USB attach failed: VM has no USB controller for registry \(record.registryIDText).")
                return
            }

            controller.attach(device: device) { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }

                    guard self.pendingAttachAccessoryID == registryID else {
                        self.appendEvent("USB attach completion ignored for registry \(record.registryIDText): attach is no longer current.")
                        return
                    }

                    self.pendingAttachAccessoryID = nil

                    if let error {
                        self.statusMessage = error.localizedDescription
                        self.appendEvent("USB attach failed: \(error.localizedDescription)")
                        self.suppressAutoAttach(
                            for: record,
                            interval: USBPassthroughPolicy.attachFailureSuppressionInterval,
                            reason: "VZ USB controller attach failed: \(error.localizedDescription)"
                        )
                    } else {
                        self.attachedAccessoryID = registryID
                        self.attachedDevice = device
                        self.statusMessage = "USB accessory attached."
                        self.appendEvent("USB accessory attached: registry \(record.registryIDText).")
                    }
                }
            }
        } catch {
            pendingAttachAccessoryID = nil
            statusMessage = error.localizedDescription
            appendEvent("USB passthrough device creation failed for registry \(record.registryIDText): \(error.localizedDescription)")
            suppressAutoAttach(
                for: record,
                interval: USBPassthroughPolicy.attachFailureSuppressionInterval,
                reason: "VZ passthrough device creation failed: \(error.localizedDescription)"
            )
        }
    }

    func detachAccessory() {
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

        controller.detach(device: device) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    if let detachedRecord {
                        self.manuallyDetachedDescriptorKeys.remove(detachedRecord.descriptorIdentityKey)
                        self.manualDetachEventSuppressedUntilByDescriptor.removeValue(forKey: detachedRecord.descriptorIdentityKey)
                    }
                    self.manualPassthroughDisconnectSuppressedUntil = nil
                    self.statusMessage = error.localizedDescription
                    self.appendEvent("USB detach failed: \(error.localizedDescription)")
                } else {
                    self.attachedAccessoryID = nil
                    self.attachedDevice = nil
                    self.statusMessage = "USB accessory detached from VM."
                    self.appendEvent("USB accessory detached from VM by user.")
                }
            }
        }
    }

    func prepareForApplicationTermination() {
        appendEvent("Application terminating.")
    }

    func reloadWireGuardConfiguration() {
        reloadWireGuardConfigurationFromAssets(reason: "manual request", reportIfMissing: true)
    }

    func copyWireGuardConfiguration() {
        guard canExportWireGuardConfiguration else {
            wireGuardStatusMessage = "Wait for RTPVM_WG_ENDPOINT before copying the host configuration."
            appendEvent("WireGuard configuration not copied: VM endpoint is unknown.")
            return
        }

        Clipboard.copy(wireGuardHostConfiguration)
        wireGuardStatusMessage = "WireGuard host configuration copied."
        appendEvent("WireGuard host configuration copied to clipboard.")
    }

    func saveWireGuardConfiguration() {
        guard canExportWireGuardConfiguration else {
            wireGuardStatusMessage = "Wait for RTPVM_WG_ENDPOINT before saving the host configuration."
            appendEvent("WireGuard configuration not saved: VM endpoint is unknown.")
            return
        }

        guard let url = FilePicker.chooseSaveFile(
            title: "Save WireGuard Configuration",
            defaultName: "rtpvm.conf"
        ) else {
            return
        }

        do {
            try wireGuardHostConfiguration.write(to: url, atomically: true, encoding: .utf8)
            wireGuardStatusMessage = "WireGuard host configuration saved."
            appendEvent("WireGuard host configuration saved to \(url.path).")
        } catch {
            wireGuardStatusMessage = error.localizedDescription
            appendEvent("WireGuard configuration save failed: \(error.localizedDescription)")
        }
    }

    func clearWireGuardEndpoint() {
        clearWireGuardEndpoint(reason: "manual request")
    }

    func clearConsole() {
        consoleText = ""
        consoleOutputData = Data()
        consoleOutputSequence = 0
        consoleResetSequence &+= 1
    }

    @discardableResult
    func sendConsoleBytes(_ data: Data) -> Bool {
        guard !data.isEmpty else {
            return true
        }

        guard canSendConsoleInput else {
            appendEvent("Console input not sent: VM console input is unavailable.")
            return false
        }

        return writeConsolePayload(data, failureContext: "Console input")
    }

    private func writeConsolePayload(_ payload: Data, failureContext: String) -> Bool {
        guard let inputPipe = runtimeResources?.consoleInputPipe else {
            appendEvent("\(failureContext) not sent: VM console input is unavailable.")
            return false
        }

        let fileDescriptor = inputPipe.fileHandleForWriting.fileDescriptor
        var offset = 0

        let success = payload.withUnsafeBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else {
                return true
            }

            while offset < rawBuffer.count {
                let written = Darwin.write(fileDescriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if written <= 0 {
                    return false
                }

                offset += written
            }

            return true
        }

        if !success {
            appendEvent("\(failureContext) write failed: errno \(errno).")
            return false
        }

        return true
    }

    func clearEventLog() {
        eventLog = ""
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

    private func restoreAssetSelections() {
        kernelURL = restoredFileURL(forKey: DefaultsKey.kernelURLPath)
        initialRamdiskURL = restoredFileURL(forKey: DefaultsKey.initialRamdiskURLPath)

        if let restoredDiskURL = restoredFileURL(forKey: DefaultsKey.diskImageURLPath),
           restoredDiskURL.pathExtension.localizedCaseInsensitiveCompare("iso") != .orderedSame {
            diskImageURL = restoredDiskURL
        } else {
            diskImageURL = nil
        }

        if canStartVirtualMachine {
            statusMessage = "Previous VM asset selection restored."
        } else if kernelURL != nil || initialRamdiskURL != nil || diskImageURL != nil {
            statusMessage = "Select missing Alpine RTPVM assets to begin."
        }
    }

    private func resolveVMAssetFolder(_ directoryURL: URL) throws -> VMAssetFolderSelection {
        let directory = directoryURL.standardizedFileURL
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw VMAssetFolderLoadError.notDirectory(directory)
        }

        let searchDirectories = [
            directory,
            directory.appendingPathComponent("boot", isDirectory: true)
        ]

        guard let kernelURL = firstAsset(
            in: searchDirectories,
            preferredNames: ["Image-lts", "Image-virt"],
            prefix: "Image-"
        ) else {
            throw VMAssetFolderLoadError.missingKernel(directory)
        }

        guard let initialRamdiskURL = firstAsset(
            in: searchDirectories,
            preferredNames: ["initramfs-rtpvm-lts", "initramfs-rtpvm-virt"],
            prefix: "initramfs-rtpvm-"
        ) else {
            throw VMAssetFolderLoadError.missingInitramfs(directory)
        }

        return VMAssetFolderSelection(kernelURL: kernelURL, initialRamdiskURL: initialRamdiskURL)
    }

    private func firstAsset(
        in directories: [URL],
        preferredNames: [String],
        prefix: String
    ) -> URL? {
        for directory in directories {
            for preferredName in preferredNames {
                let url = directory.appendingPathComponent(preferredName, isDirectory: false)
                if isRegularFile(url) {
                    return url
                }
            }
        }

        for directory in directories {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            if let match = urls
                .filter({ $0.lastPathComponent.hasPrefix(prefix) && isRegularFile($0) })
                .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
                .first {
                return match
            }
        }

        return nil
    }

    private func isRegularFile(_ url: URL) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true
        } catch {
            return false
        }
    }

    private func vmAssetFolderURL(containing url: URL) -> URL {
        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()

        if directory.lastPathComponent == "boot" {
            return directory.deletingLastPathComponent()
        }

        return directory
    }

    private func normalizedBootCommandLine() -> String {
        let blockedKeys: Set<String> = [
            "alpine_repo",
            "ip",
            "modules",
            "panic",
            "pkgs",
            "quiet",
            "ro",
            "root",
            "rootflags",
            "rootfstype",
            "rw"
        ]

        var tokens = kernelCommandLine
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { token in
                let key = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
                return !blockedKeys.contains(key) && key != "rdinit"
            }

        if !tokens.contains(where: { $0.hasPrefix("console=") }) {
            tokens.insert("console=hvc0", at: 0)
        }

        let rdinitInsertIndex = min(tokens.lastIndex(where: { $0.hasPrefix("console=") }).map { $0 + 1 } ?? 0, tokens.count)
        tokens.insert("rdinit=/sbin/init", at: rdinitInsertIndex)

        let moduleToken = "modules=\(AlpineBootDefaults.initramfsModules)"
        let insertIndex = min(
            tokens.lastIndex(where: { $0.hasPrefix("console=") || $0.hasPrefix("rdinit=") }).map { $0 + 1 } ?? tokens.count,
            tokens.count
        )
        tokens.insert(moduleToken, at: insertIndex)

        return tokens.joined(separator: " ")
    }

    private func migrateLegacyInitramfsSelectionIfNeeded() {
        guard let initialRamdiskURL,
              initialRamdiskURL.lastPathComponent.hasPrefix("initramfs-tui-") else {
            return
        }

        let replacementName = initialRamdiskURL.lastPathComponent.replacingOccurrences(
            of: "initramfs-tui-",
            with: "initramfs-rtpvm-",
            options: [.anchored]
        )
        let replacementURL = initialRamdiskURL
            .deletingLastPathComponent()
            .appendingPathComponent(replacementName, isDirectory: false)

        guard FileManager.default.fileExists(atPath: replacementURL.path) else {
            return
        }

        self.initialRamdiskURL = replacementURL
        appendEvent("Updated legacy initramfs selection to \(replacementName).")
    }

    private func appendAssetSelectionSummaryIfNeeded() {
        var restoredAssets: [String] = []

        if kernelURL != nil {
            restoredAssets.append("kernel")
        }
        if initialRamdiskURL != nil {
            restoredAssets.append("initramfs")
        }
        if diskImageURL != nil {
            restoredAssets.append("scratch disk")
        }

        if !restoredAssets.isEmpty {
            appendEvent("Restored previous VM asset selection: \(restoredAssets.joined(separator: ", ")).")
        }
    }

    private func reloadWireGuardConfigurationFromAssets(
        reason: String,
        reportIfMissing: Bool = false
    ) {
        let assetFolderURL = configuredVMAssetFolderURL

        do {
            if let result = try wireGuardConfigurationLoader.loadGeneratedSettings(
                from: assetFolderURL,
                preservingEndpoint: wireGuardSettings.endpoint
            ) {
                wireGuardSettings = result.settings
                wireGuardStatusMessage = "Loaded generated WireGuard configuration."
                appendEvent("Loaded generated WireGuard configuration from \(result.sourceURL.path): \(reason).")
                return
            }

            if reportIfMissing {
                wireGuardStatusMessage = "Generated WireGuard configs were not found near the selected assets."
                appendEvent("WireGuard configuration not loaded: selected VM asset folder must contain wireguard/wg-server.conf and wireguard/wg-client.conf.")
            }
        } catch {
            wireGuardStatusMessage = error.localizedDescription
            appendEvent("WireGuard configuration load failed: \(error.localizedDescription)")
        }
    }

    private func restoredFileURL(forKey key: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: path)
        if let migratedURL = migratedLegacyAssetURL(from: url) {
            UserDefaults.standard.set(migratedURL.standardizedFileURL.path, forKey: key)
            return migratedURL
        }

        return url
    }

    private func migratedLegacyAssetURL(from url: URL) -> URL? {
        let legacySegment = "/script/VMAssets/"
        let migratedSegment = "/script/assets/"
        let path = url.standardizedFileURL.path

        if let range = path.range(of: legacySegment) {
            let migratedPath = path.replacingCharacters(in: range, with: migratedSegment)
            guard FileManager.default.fileExists(atPath: migratedPath) else {
                return nil
            }

            return URL(fileURLWithPath: migratedPath)
        }

        guard let assetRange = path.range(of: migratedSegment) else {
            return nil
        }

        let suffix = path[assetRange.upperBound...]
        let pathComponents = suffix.split(separator: "/")

        guard pathComponents.count >= 3,
              pathComponents[1] == "boot",
              let fileName = pathComponents.last else {
            return nil
        }

        let flattenedPath = String(path[..<assetRange.upperBound]) + String(fileName)
        guard FileManager.default.fileExists(atPath: flattenedPath) else {
            return nil
        }

        return URL(fileURLWithPath: flattenedPath)
    }

    private func persistFileURL(_ url: URL?, forKey key: String) {
        if let path = url?.standardizedFileURL.path {
            UserDefaults.standard.set(path, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func appendSelectedAssetDiagnostics(kernelURL: URL, initialRamdiskURL: URL) {
        appendEvent(assetDiagnosticText(label: "Kernel", url: kernelURL))
        appendEvent(assetDiagnosticText(label: "Initramfs", url: initialRamdiskURL))
    }

    private func assetDiagnosticText(label: String, url: URL) -> String {
        let path = url.standardizedFileURL.path

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            var details: [String] = []

            if let size = (attributes[.size] as? NSNumber)?.int64Value {
                details.append("size=\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
            }

            if let modified = attributes[.modificationDate] as? Date {
                details.append("modified=\(Self.assetDateFormatter.string(from: modified))")
            }

            let suffix = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
            return "\(label) asset: \(path)\(suffix)"
        } catch {
            return "\(label) asset: \(path) (metadata unavailable: \(error.localizedDescription))"
        }
    }

    private func refreshRuntimeEntitlements() {
        let snapshot = RuntimeEntitlementSnapshot.current
        if snapshot != runtimeEntitlements {
            runtimeEntitlements = snapshot
            appendRuntimeEntitlementSummary()
        }
    }

    private func appendRuntimeEntitlementSummary() {
        let summary = RuntimeEntitlement.allCases.map { entitlement in
            "\(entitlement.rawValue)=\(runtimeEntitlements.has(entitlement) ? "present" : "missing")"
        }
        appendEvent("Runtime entitlements: \(summary.joined(separator: ", ")).")
    }

    private func reportMissingEntitlement(_ entitlement: RuntimeEntitlement, action: String) {
        statusMessage = "\(entitlement.label) entitlement missing."
        appendEvent("\(action) not started: missing \(entitlement.rawValue). The default RNDIS Tethering VM Passthrough scheme is for local UI builds; run the RNDIS Tethering VM Passthrough Runtime scheme with an approved provisioning profile to exercise this runtime path.")
    }

    private func clearWireGuardEndpoint(reason: String) {
        guard wireGuardSettings.endpoint != nil else {
            return
        }

        var settings = wireGuardSettings
        settings.endpoint = nil
        wireGuardSettings = settings
        wireGuardStatusMessage = "Waiting for RTPVM_WG_ENDPOINT from guest."
        appendEvent("WireGuard endpoint cleared: \(reason).")
    }

    private func updateWireGuardEndpoint(from text: String) {
        let marker = "RTPVM_WG_ENDPOINT="
        guard let markerRange = text.range(of: marker, options: [.backwards]) else {
            return
        }

        let suffix = text[markerRange.upperBound...]
        guard let token = suffix.split(whereSeparator: \.isWhitespace).first else {
            return
        }

        let endpoint = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        guard endpoint.contains(":"),
              endpoint != wireGuardSettings.endpoint else {
            return
        }

        var settings = wireGuardSettings
        settings.endpoint = endpoint
        wireGuardSettings = settings
        wireGuardStatusMessage = "WireGuard guest address discovered: \(endpoint)."
        appendEvent("WireGuard guest address discovered from guest console: \(endpoint).")
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
        appendEvent("USB connected: \(record.descriptorDiagnosticText), registry \(record.registryIDText), \(accessoryEventContext(for: record, kind: "connect")).")
        autoAttachIfPossible(accessory, record: record)
    }

    private func removeAccessory(_ accessory: AAUSBAccessory) {
        let record = USBAccessoryRecord(accessory: accessory)
        let wasSelected = selectedAccessoryID == accessory.registryID
        let wasAttached = attachedAccessoryID == accessory.registryID

        if manualDetachEventSuppressionRemaining(for: record) != nil {
            accessoryObjects[accessory.registryID] = nil
            appendEvent("USB AccessoryAccess disconnect ignored during manual VM detach: registry \(record.registryIDText), \(accessoryEventContext(for: record, kind: "disconnect")).")
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
            appendEvent("USB disconnected while VZ attach was pending for registry \(record.registryIDText).")
        }

        appendEvent("USB disconnected: \(record.descriptorDiagnosticText), registry \(record.registryIDText), wasSelected=\(wasSelected), wasAttached=\(wasAttached), \(accessoryEventContext(for: record, kind: "disconnect")).")

        if wasAttached {
            appendEvent("USB disconnect matched the attached passthrough accessory; restarting VM to recreate a fixed usb0 session.")
            restartVirtualMachineAfterUSBDetach(reason: "AccessoryAccess disconnect for attached registry \(record.registryIDText)")
        }
    }

    private func autoAttachIfPossible(_ accessory: AAUSBAccessory, record: USBAccessoryRecord) {
        guard runtimeState == .running, let virtualMachine else {
            return
        }

        guard attachedAccessoryID == nil, attachedDevice == nil, pendingAttachAccessoryID == nil else {
            appendEvent("USB auto-attach skipped for registry \(record.registryIDText): single passthrough device limit is already active.")
            return
        }

        guard record.hasConfigurationDescriptor else {
            appendEvent("USB auto-attach skipped for registry \(record.registryIDText): AccessoryAccess reported no configuration descriptor. Select the device and attach manually only after it stabilizes.")
            return
        }

        guard !isManualDetachedAutoAttachBlocked(for: record) else {
            return
        }

        guard !isAutoAttachSuppressed(for: record) else {
            return
        }

        appendEvent("USB auto-attach on connect: registry \(record.registryIDText).")
        attach(accessory, record: record, to: virtualMachine, reason: "auto connect")
    }

    private func autoAttachAvailableAccessoryIfPossible(reason: String) {
        guard runtimeState == .running, let virtualMachine else {
            return
        }

        guard attachedAccessoryID == nil, attachedDevice == nil, pendingAttachAccessoryID == nil else {
            return
        }

        guard let record = accessories.first(where: { record in
            record.hasConfigurationDescriptor
                && !manuallyDetachedDescriptorKeys.contains(record.descriptorIdentityKey)
                && attachSuppressionRemaining(for: record) == nil
        }),
              let accessory = accessoryObjects[record.id] else {
            appendEvent("USB auto-attach not started for \(reason): no attachable AccessoryAccess device is available.")
            return
        }

        appendEvent("USB auto-attach on \(reason): registry \(record.registryIDText).")
        attach(accessory, record: record, to: virtualMachine, reason: reason)
    }

    private func noteManualDetach(for record: USBAccessoryRecord) {
        let suppressedUntil = Date().addingTimeInterval(USBPassthroughPolicy.manualDetachAccessoryEventGraceInterval)
        manuallyDetachedDescriptorKeys.insert(record.descriptorIdentityKey)
        manualDetachEventSuppressedUntilByDescriptor[record.descriptorIdentityKey] = suppressedUntil
        appendEvent("USB manual detach policy: keeping \(record.registryIDText) in the device list and blocking automatic reattach until the next manual attach.")
    }

    private func isManualDetachedAutoAttachBlocked(for record: USBAccessoryRecord) -> Bool {
        guard manuallyDetachedDescriptorKeys.contains(record.descriptorIdentityKey) else {
            return false
        }

        appendEvent("USB auto-attach skipped for registry \(record.registryIDText): device was manually detached from the VM.")
        return true
    }

    private func isAutoAttachSuppressed(for record: USBAccessoryRecord) -> Bool {
        guard let remaining = attachSuppressionRemaining(for: record) else { return false }

        appendEvent("USB auto-attach suppressed for registry \(record.registryIDText): retry allowed in \(Self.secondsText(remaining)).")
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
        appendEvent("USB auto-attach suppressed for descriptor \(record.usbIDText) for \(Self.secondsText(interval)): \(reason)")
    }

    private func manualDetachEventSuppressionRemaining(for record: USBAccessoryRecord) -> TimeInterval? {
        guard let suppressedUntil = manualDetachEventSuppressedUntilByDescriptor[record.descriptorIdentityKey] else {
            return nil
        }

        let now = Date()
        guard suppressedUntil > now else {
            manualDetachEventSuppressedUntilByDescriptor[record.descriptorIdentityKey] = nil
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

    private func stopAccessoryMonitoring(reason: String) {
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
        manualPassthroughDisconnectSuppressedUntil = nil

        monitor.stop { [weak self] in
            Task { @MainActor in
                self?.appendEvent("AccessoryAccess USB listener stopped: \(reason)")
            }
        }
    }

    private func makeDelegate() -> VirtualMachineDelegateBox {
        let delegate = VirtualMachineDelegateBox()

        delegate.onGuestDidStop = { [weak self] in
            Task { @MainActor in
                self?.markStopped(message: "Guest shut down.")
            }
        }

        delegate.onStopError = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }

                self.runtimeState = .failed
                self.statusMessage = error.localizedDescription
                self.isRestartingAfterUSBDetach = false
                self.releaseRuntimeResources()
                self.appendEvent("VM stopped with error: \(error.localizedDescription)")
            }
        }

        delegate.onNetworkDisconnect = { [weak self] error in
            Task { @MainActor in
                self?.appendEvent("VM network attachment disconnected: \(error.localizedDescription)")
            }
        }

        delegate.onUSBPassthroughDisconnect = { [weak self] in
            Task { @MainActor in
                guard let self else { return }

                let attachedRegistry = self.attachedAccessoryID.map(Self.registryIDText) ?? "none"
                if self.isManualPassthroughDisconnectSuppressed() {
                    self.attachedAccessoryID = nil
                    self.attachedDevice = nil
                    self.appendEvent("USB passthrough disconnect ignored because it was produced by a manual VM detach, attached registry \(attachedRegistry).")
                    return
                }

                self.attachedAccessoryID = nil
                self.attachedDevice = nil
                self.appendEvent("USB passthrough device disconnected by the system, attached registry \(attachedRegistry).")
                self.restartVirtualMachineAfterUSBDetach(reason: "Virtualization USB passthrough disconnect for registry \(attachedRegistry)")
            }
        }

        return delegate
    }

    private func restartVirtualMachineAfterUSBDetach(reason: String) {
        guard let virtualMachine else {
            appendEvent("USB detach restart skipped: VM is not available (\(reason)).")
            return
        }

        guard runtimeState == .running || runtimeState == .starting else {
            appendEvent("USB detach restart skipped while VM state is \(runtimeState.rawValue): \(reason).")
            return
        }

        guard !isRestartingAfterUSBDetach else {
            appendEvent("USB detach restart already pending: \(reason).")
            return
        }

        isRestartingAfterUSBDetach = true
        runtimeState = .stopping
        statusMessage = "USB detached; restarting VM."
        attachedAccessoryID = nil
        attachedDevice = nil
        pendingAttachAccessoryID = nil
        appendEvent("USB detach policy: restarting VM to recreate the fixed usb0 RNDIS session (\(reason)).")

        virtualMachine.stop { [weak self] error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.isRestartingAfterUSBDetach = false
                    self.runtimeState = .failed
                    self.statusMessage = error.localizedDescription
                    self.releaseRuntimeResources()
                    self.appendEvent("VM restart after USB detach failed while stopping VM: \(error.localizedDescription)")
                    return
                }

                self.markStopped(message: "VM stopped after USB detach.")
                self.isRestartingAfterUSBDetach = false
                self.startVirtualMachine()
            }
        }
    }

    private func markStopped(message: String) {
        runtimeState = .stopped
        statusMessage = message
        attachedAccessoryID = nil
        attachedDevice = nil
        pendingAttachAccessoryID = nil
        virtualMachine = nil
        vmDelegate = nil
        releaseRuntimeResources()
        appendEvent(message)
    }

    private func installConsoleReader(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                Task { @MainActor in
                    guard let self else { return }
                    let message = self.hasReceivedConsoleOutput
                        ? "Console output pipe closed."
                        : "Console output pipe closed before any data was received."
                    self.appendEvent(message)
                }
                return
            }

            Task { @MainActor in
                self?.appendConsole(data)
            }
        }
    }

    private func releaseRuntimeResources() {
        cancelConsoleOutputWatchdog()
        runtimeResources?.consoleOutputPipe.fileHandleForReading.readabilityHandler = nil
        runtimeResources = nil
    }

    private func appendConsole(_ data: Data) {
        if !hasReceivedConsoleOutput {
            hasReceivedConsoleOutput = true
            cancelConsoleOutputWatchdog()
            appendEvent("Console output started: first read \(data.count) byte(s).")
        }

        appendConsoleOutputData(data)

        if let text = String(data: data, encoding: .utf8) {
            consoleText.append(text)
            updateWireGuardEndpoint(from: consoleText)
        } else {
            consoleText.append(data.map { String(format: "%02X", $0) }.joined(separator: " "))
            consoleText.append("\n")
        }
        trimConsoleIfNeeded()
    }

    private func appendEvent(_ message: String) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        eventLog.append("[\(timestamp)] \(message)\n")
        trimEventLogIfNeeded()
    }

    private func accessoryEventContext(for record: USBAccessoryRecord, kind: String) -> String {
        accessoryEventSequence += 1

        let now = Date()
        let previousEvent = lastAccessoryEventByDescriptor[record.descriptorIdentityKey]
        lastAccessoryEventByDescriptor[record.descriptorIdentityKey] = (kind: kind, date: now)

        var components = [
            "event #\(accessoryEventSequence)",
            "vm=\(runtimeState.rawValue)"
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

    private func trimConsoleIfNeeded() {
        let maximumCharacters = 200_000
        if consoleText.count > maximumCharacters {
            consoleText.removeFirst(consoleText.count - maximumCharacters)
        }
    }

    private func appendConsoleOutputData(_ data: Data) {
        var outputData = consoleOutputData
        outputData.append(data)

        let maximumBytes = 4_000_000
        if outputData.count > maximumBytes {
            outputData.removeFirst(outputData.count - maximumBytes)
            consoleResetSequence &+= 1
        }

        consoleOutputData = outputData
        consoleOutputSequence &+= 1
    }

    private func scheduleConsoleOutputWatchdog() {
        cancelConsoleOutputWatchdog()
        consoleOutputWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled else { return }
            guard self.runtimeState == .running, !self.hasReceivedConsoleOutput else { return }

            self.appendEvent("No VM console output received after 15s. Selected kernel/initramfs assets are logged above; confirm the kernel is Image-lts and the initramfs is initramfs-rtpvm-lts regenerated after the latest script changes.")
        }
    }

    private func cancelConsoleOutputWatchdog() {
        consoleOutputWatchdogTask?.cancel()
        consoleOutputWatchdogTask = nil
    }

    private func trimEventLogIfNeeded() {
        let maximumCharacters = 60_000
        if eventLog.count > maximumCharacters {
            eventLog.removeFirst(eventLog.count - maximumCharacters)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let assetDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private enum DefaultsKey {
        static let kernelURLPath = "VMAssets.kernelURLPath"
        static let initialRamdiskURLPath = "VMAssets.initialRamdiskURLPath"
        static let diskImageURLPath = "VMAssets.diskImageURLPath"
    }

    private static func registryIDText(_ registryID: UInt64) -> String {
        "0x" + String(registryID, radix: 16, uppercase: true)
    }

    private static func secondsText(_ interval: TimeInterval) -> String {
        String(format: "%.1fs", max(0, interval))
    }

}
