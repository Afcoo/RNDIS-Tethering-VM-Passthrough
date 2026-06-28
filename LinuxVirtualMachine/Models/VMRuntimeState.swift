/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum VMRuntimeState: String {
    case idle
    case starting
    case running
    case stopping
    case stopped
    case failed

    var title: String {
        switch self {
        case .idle:
            return "Idle"
        case .starting:
            return "Starting"
        case .running:
            return "Running"
        case .stopping:
            return "Stopping"
        case .stopped:
            return "Stopped"
        case .failed:
            return "Failed"
        }
    }
}
