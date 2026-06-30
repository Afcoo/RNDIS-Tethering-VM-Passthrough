/*
Copyright (C) 2026 Afcoo.
*/

import Darwin
import Foundation
import Virtualization

struct VMConfigurationInput {
    let kernelURL: URL
    let initialRamdiskURL: URL
    let diskImageURL: URL?
    let cpuCount: Int
    let memorySizeBytes: UInt64
    let bootCommandLine: String
    let guestMACAddress: String
}

final class VMRuntimeResources {
    let consoleInputPipe: Pipe
    let consoleOutputPipe: Pipe

    init(consoleInputPipe: Pipe, consoleOutputPipe: Pipe) {
        self.consoleInputPipe = consoleInputPipe
        self.consoleOutputPipe = consoleOutputPipe
    }
}

struct VMBuildResult {
    let configuration: VZVirtualMachineConfiguration
    let resources: VMRuntimeResources
}

enum VMConfigurationFactory {
    static func build(input: VMConfigurationInput) throws -> VMBuildResult {
        let consoleInputPipe = Pipe()
        let consoleOutputPipe = Pipe()

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = VZGenericPlatformConfiguration()
        configuration.cpuCount = input.cpuCount
        configuration.memorySize = input.memorySizeBytes
        configuration.bootLoader = createBootLoader(input: input)
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.serialPorts = [createConsoleConfiguration(inputPipe: consoleInputPipe, outputPipe: consoleOutputPipe)]
        configuration.storageDevices = try createStorageDevices(url: input.diskImageURL)
        configuration.usbControllers = [VZXHCIControllerConfiguration()]
        configuration.networkDevices = [try createNetworkDevice(macAddress: input.guestMACAddress)]

        try configuration.validate()

        return VMBuildResult(
            configuration: configuration,
            resources: VMRuntimeResources(consoleInputPipe: consoleInputPipe, consoleOutputPipe: consoleOutputPipe)
        )
    }

    private static func createBootLoader(input: VMConfigurationInput) -> VZBootLoader {
        let bootLoader = VZLinuxBootLoader(kernelURL: input.kernelURL)
        bootLoader.initialRamdiskURL = input.initialRamdiskURL
        bootLoader.commandLine = input.bootCommandLine
        return bootLoader
    }

    private static func createConsoleConfiguration(inputPipe: Pipe, outputPipe: Pipe) -> VZSerialPortConfiguration {
        let consoleConfiguration = VZVirtioConsoleDeviceSerialPortConfiguration()
        consoleConfiguration.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: inputPipe.fileHandleForReading,
            fileHandleForWriting: outputPipe.fileHandleForWriting
        )
        return consoleConfiguration
    }

    private static func createStorageDevices(url: URL?) throws -> [VZStorageDeviceConfiguration] {
        guard let url else {
            return []
        }

        return [try createStorageDevice(url: url)]
    }

    private static func createStorageDevice(url: URL) throws -> VZStorageDeviceConfiguration {
        if url.pathExtension.localizedCaseInsensitiveCompare("iso") == .orderedSame {
            throw VMConfigurationError.unsupportedScratchDisk(url.lastPathComponent)
        }

        let attachment = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: false)
        let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: attachment)
        blockDevice.blockDeviceIdentifier = "scratch"
        return blockDevice
    }

    private static func createNetworkDevice(macAddress: String) throws -> VZNetworkDeviceConfiguration {
        guard let vzMACAddress = VZMACAddress(string: macAddress) else {
            throw VMConfigurationError.invalidMACAddress(macAddress)
        }

        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        networkDevice.macAddress = vzMACAddress
        return networkDevice
    }
}

enum VMConfigurationError: LocalizedError {
    case invalidMACAddress(String)
    case unsupportedScratchDisk(String)

    var errorDescription: String? {
        switch self {
        case .invalidMACAddress(let value):
            return "Invalid MAC address: \(value)"
        case .unsupportedScratchDisk(let value):
            return "Scratch disk must be a writable raw disk image, not ISO media: \(value)"
        }
    }
}
