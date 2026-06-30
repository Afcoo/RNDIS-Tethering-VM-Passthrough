/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case usb
    case setup
    case console
    case vpn

    var id: Self { self }

    var title: String {
        switch self {
        case .setup:
            return "VM Setup"
        case .usb:
            return "USB Devices"
        case .console:
            return "VM Console"
        case .vpn:
            return "WireGuard"
        }
    }

    var detail: String {
        switch self {
        case .setup:
            return "Kernel, disk, runtime"
        case .usb:
            return "Select a USB tethering device"
        case .console:
            return "VM serial terminal"
        case .vpn:
            return "Host configuration"
        }
    }

    var systemImage: String {
        switch self {
        case .setup:
            return "server.rack"
        case .usb:
            return "cable.connector"
        case .console:
            return "terminal"
        case .vpn:
            return "lock.shield"
        }
    }
}
