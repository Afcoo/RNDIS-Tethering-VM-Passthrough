/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

struct WireGuardSettings: Equatable {
    var serverPrivateKey: String
    var serverPublicKey: String
    var clientPrivateKey: String
    var clientPublicKey: String
    var endpoint: String?
    var serverAddress: String
    var hostTunnelAddress: String
    var hostPeerAllowedIP: String
    var listenPort: Int
    var mtu: Int
    var dnsServers: [String]
    var persistentKeepalive: Int
    var allowedIPs: String

    var hasKeyMaterial: Bool {
        !serverPrivateKey.isEmpty &&
        !serverPublicKey.isEmpty &&
        !clientPrivateKey.isEmpty &&
        !clientPublicKey.isEmpty
    }

    var allowedIPsDisplay: String {
        allowedIPs
    }

    var endpointDisplay: String {
        endpoint ?? "Waiting for RTPVM_WG_ENDPOINT from guest"
    }

    var serverInterfaceAddress: String {
        serverAddress
    }

    var hostInterfaceAddress: String {
        hostTunnelAddress
    }

    var hostAllowedIP: String {
        hostPeerAllowedIP
    }

}
