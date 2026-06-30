/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
import Security

enum RuntimeEntitlement: String, CaseIterable {
    case accessoryAccessUSB = "com.apple.developer.accessory-access.usb"
    case virtualization = "com.apple.security.virtualization"

    var label: String {
        switch self {
        case .accessoryAccessUSB:
            return "AccessoryAccess USB"
        case .virtualization:
            return "Virtualization"
        }
    }
}

struct RuntimeEntitlementSnapshot: Equatable {
    let accessoryAccessUSB: Bool
    let virtualization: Bool

    static var current: RuntimeEntitlementSnapshot {
        RuntimeEntitlementSnapshot(
            accessoryAccessUSB: RuntimeEntitlementReader.has(.accessoryAccessUSB),
            virtualization: RuntimeEntitlementReader.has(.virtualization)
        )
    }

    func has(_ entitlement: RuntimeEntitlement) -> Bool {
        switch entitlement {
        case .accessoryAccessUSB:
            return accessoryAccessUSB
        case .virtualization:
            return virtualization
        }
    }
}

enum RuntimeEntitlementReader {
    static func has(_ entitlement: RuntimeEntitlement) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, entitlement.rawValue as CFString, nil) else {
            return false
        }

        return (value as? Bool) == true
    }
}
