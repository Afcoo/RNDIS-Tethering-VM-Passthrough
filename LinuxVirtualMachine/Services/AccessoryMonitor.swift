/*
Copyright (C) 2026 Afcoo.
*/

import AccessoryAccess
import Foundation

final class AccessoryMonitor: NSObject {
    var onConnect: ((AAUSBAccessory) -> Void)?
    var onDisconnect: ((AAUSBAccessory) -> Void)?

    private var isRegistered = false

    func start(completion: @escaping (Result<[AAUSBAccessory], Error>) -> Void) {
        guard !isRegistered else {
            completion(.success([]))
            return
        }

        AAUSBAccessoryManager.shared.registerListener(self, matchingCriteria: []) { [weak self] accessories, error in
            if let error {
                completion(.failure(error))
                return
            }

            self?.isRegistered = true
            completion(.success(accessories))
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        guard isRegistered else {
            completion?()
            return
        }

        AAUSBAccessoryManager.shared.unregisterListener(self) { [weak self] in
            self?.isRegistered = false
            completion?()
        }
    }
}

extension AccessoryMonitor: AAUSBAccessoryListener {
    func usbAccessoryDidConnect(_ usbAccessory: AAUSBAccessory) {
        onConnect?(usbAccessory)
    }

    func usbAccessoryDidDisconnect(_ usbAccessory: AAUSBAccessory) {
        onDisconnect?(usbAccessory)
    }
}
