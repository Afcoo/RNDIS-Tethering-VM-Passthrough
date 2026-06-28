/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
import Virtualization

final class VirtualMachineDelegateBox: NSObject {
    var onGuestDidStop: (() -> Void)?
    var onStopError: ((Error) -> Void)?
    var onNetworkDisconnect: ((Error) -> Void)?
    var onUSBPassthroughDisconnect: (() -> Void)?
}

extension VirtualMachineDelegateBox: VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        DispatchQueue.main.async { [weak self] in
            self?.onGuestDidStop?()
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onStopError?(error)
        }
    }

    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: Error
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.onNetworkDisconnect?(error)
        }
    }
}

extension VirtualMachineDelegateBox: VZUSBController.Delegate {
    func usbController(_ usbController: VZUSBController, usbPassthroughDeviceDidDisconnect device: VZUSBPassthroughDevice) {
        DispatchQueue.main.async { [weak self] in
            self?.onUSBPassthroughDisconnect?()
        }
    }
}
