/*
Copyright (C) 2026 Afcoo.
*/

import AccessoryAccess
import Foundation

struct USBInterfaceSummary: Hashable {
    let number: Int
    let alternateSetting: Int
    let endpointCount: Int
    let interfaceClass: Int
    let interfaceSubClass: Int
    let interfaceProtocol: Int

    var diagnosticText: String {
        String(
            format: "if%d alt%d ep%d class %02X:%02X:%02X",
            number,
            alternateSetting,
            endpointCount,
            interfaceClass,
            interfaceSubClass,
            interfaceProtocol
        )
    }
}

struct USBAccessoryRecord: Identifiable, Hashable {
    let id: UInt64
    let vendorID: Int?
    let productID: Int?
    let bcdUSB: Int?
    let bcdDevice: Int?
    let deviceClass: Int?
    let deviceSubClass: Int?
    let deviceProtocol: Int?
    let configurationValue: Int?
    let configurationInterfaceCount: Int?
    let configurationAttributes: Int?
    let configurationMaxPowerMilliamps: Int?
    let interfaces: [USBInterfaceSummary]
    let hasConfigurationDescriptor: Bool
    let deviceDescriptorHash: String
    let configurationDescriptorHash: String

    init(accessory: AAUSBAccessory) {
        let bytes = [UInt8](accessory.deviceDescriptorData)
        let configurationBytes = accessory.configurationDescriptorData.map { [UInt8]($0) }
        self.id = accessory.registryID
        self.vendorID = Self.littleEndianUInt16(bytes, offset: 8)
        self.productID = Self.littleEndianUInt16(bytes, offset: 10)
        self.bcdUSB = Self.littleEndianUInt16(bytes, offset: 2)
        self.bcdDevice = Self.littleEndianUInt16(bytes, offset: 12)
        self.deviceClass = Self.byte(bytes, offset: 4)
        self.deviceSubClass = Self.byte(bytes, offset: 5)
        self.deviceProtocol = Self.byte(bytes, offset: 6)
        self.configurationValue = configurationBytes.flatMap { Self.byte($0, offset: 5) }
        self.configurationInterfaceCount = configurationBytes.flatMap { Self.byte($0, offset: 4) }
        self.configurationAttributes = configurationBytes.flatMap { Self.byte($0, offset: 7) }
        self.configurationMaxPowerMilliamps = configurationBytes.flatMap { Self.byte($0, offset: 8) }.map { $0 * 2 }
        self.interfaces = configurationBytes.map(Self.interfaceSummaries(in:)) ?? []
        self.hasConfigurationDescriptor = configurationBytes?.isEmpty == false
        self.deviceDescriptorHash = Self.fnv1a64(accessory.deviceDescriptorData)
        self.configurationDescriptorHash = Self.fnv1a64(accessory.configurationDescriptorData)
    }

    var registryIDText: String {
        "0x" + String(id, radix: 16, uppercase: true)
    }

    var usbIDText: String {
        guard let vendorID, let productID else {
            return "Unknown VID:PID"
        }
        return String(format: "%04X:%04X", vendorID, productID)
    }

    var classText: String {
        let values = [deviceClass, deviceSubClass, deviceProtocol].map { value -> String in
            guard let value else { return "--" }
            return String(format: "%02X", value)
        }
        return values.joined(separator: ":")
    }

    var descriptorDiagnosticText: String {
        [
            "VID:PID \(usbIDText)",
            "class \(classText)",
            "bcdUSB \(Self.wordHex(bcdUSB))",
            "bcdDevice \(Self.wordHex(bcdDevice))",
            "config \(configurationDiagnosticText)",
            "interfaces \(interfaceDiagnosticText)",
            "hash dev=\(deviceDescriptorHash) cfg=\(configurationDescriptorHash)"
        ].joined(separator: ", ")
    }

    var descriptorIdentityKey: String {
        [
            usbIDText,
            classText,
            deviceDescriptorHash,
            configurationDescriptorHash
        ].joined(separator: "|")
    }

    var configurationDiagnosticText: String {
        guard configurationValue != nil || configurationInterfaceCount != nil else {
            return "none"
        }

        let maxPower = configurationMaxPowerMilliamps.map { "\($0)mA" } ?? "--"
        return "value \(Self.numberText(configurationValue)) ifaces \(Self.numberText(configurationInterfaceCount)) attrs \(Self.byteHex(configurationAttributes)) maxPower \(maxPower)"
    }

    var interfaceDiagnosticText: String {
        guard !interfaces.isEmpty else {
            return "none"
        }

        return interfaces.map(\.diagnosticText).joined(separator: "; ")
    }

    private static func byte(_ bytes: [UInt8], offset: Int) -> Int? {
        guard bytes.indices.contains(offset) else {
            return nil
        }
        return Int(bytes[offset])
    }

    private static func littleEndianUInt16(_ bytes: [UInt8], offset: Int) -> Int? {
        guard bytes.indices.contains(offset), bytes.indices.contains(offset + 1) else {
            return nil
        }
        return Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }

    private static func interfaceSummaries(in bytes: [UInt8]) -> [USBInterfaceSummary] {
        var summaries: [USBInterfaceSummary] = []
        var offset = 0

        while offset + 1 < bytes.count {
            let descriptorLength = Int(bytes[offset])
            let descriptorType = Int(bytes[offset + 1])
            guard descriptorLength > 0 else {
                break
            }

            let nextOffset = offset + descriptorLength
            if descriptorType == 4, nextOffset <= bytes.count, descriptorLength >= 9 {
                summaries.append(
                    USBInterfaceSummary(
                        number: Int(bytes[offset + 2]),
                        alternateSetting: Int(bytes[offset + 3]),
                        endpointCount: Int(bytes[offset + 4]),
                        interfaceClass: Int(bytes[offset + 5]),
                        interfaceSubClass: Int(bytes[offset + 6]),
                        interfaceProtocol: Int(bytes[offset + 7])
                    )
                )
            }

            offset = nextOffset
        }

        return summaries
    }

    private static func fnv1a64(_ data: Data?) -> String {
        guard let data, !data.isEmpty else {
            return "none"
        }

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }

        return String(format: "%016llX", hash)
    }

    private static func wordHex(_ value: Int?) -> String {
        guard let value else {
            return "----"
        }

        return String(format: "0x%04X", value)
    }

    private static func byteHex(_ value: Int?) -> String {
        guard let value else {
            return "--"
        }

        return String(format: "0x%02X", value)
    }

    private static func numberText(_ value: Int?) -> String {
        guard let value else {
            return "--"
        }

        return "\(value)"
    }
}
