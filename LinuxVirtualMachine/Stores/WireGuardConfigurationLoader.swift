/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

struct WireGuardConfigurationLoader {
    private let serverConfigurationFileName = "wg-server.conf"
    private let clientConfigurationFileName = "wg-client.conf"
    private let emptyServerAddress = "10.100.0.1/24"
    private let emptyHostTunnelAddress = "10.100.0.2/24"
    private let emptyHostPeerAllowedIP = "10.100.0.2/32"
    private let emptyListenPort = 51820
    private let emptyMTU = 1420
    private let emptyPersistentKeepalive = 25
    private let emptyAllowedIPs = "10.100.0.0/24, 0.0.0.0/1, 128.0.0.0/1"

    func emptySettings(endpoint: String? = nil) -> WireGuardSettings {
        WireGuardSettings(
            serverPrivateKey: "",
            serverPublicKey: "",
            clientPrivateKey: "",
            clientPublicKey: "",
            endpoint: endpoint,
            serverAddress: emptyServerAddress,
            hostTunnelAddress: emptyHostTunnelAddress,
            hostPeerAllowedIP: emptyHostPeerAllowedIP,
            listenPort: emptyListenPort,
            mtu: emptyMTU,
            dnsServers: [],
            persistentKeepalive: emptyPersistentKeepalive,
            allowedIPs: emptyAllowedIPs
        )
    }

    func loadGeneratedSettings(
        from assetFolderURL: URL?,
        preservingEndpoint endpoint: String?
    ) throws -> (settings: WireGuardSettings, sourceURL: URL)? {
        guard let assetFolderURL else {
            return nil
        }

        let wireGuardDirectory = assetFolderURL
            .appendingPathComponent("wireguard", isDirectory: true)
        let serverURL = wireGuardDirectory
            .appendingPathComponent(serverConfigurationFileName, isDirectory: false)
        let clientURL = wireGuardDirectory
            .appendingPathComponent(clientConfigurationFileName, isDirectory: false)

        guard FileManager.default.fileExists(atPath: serverURL.path),
              FileManager.default.fileExists(atPath: clientURL.path) else {
            return nil
        }

        let serverText = try String(contentsOf: serverURL, encoding: .utf8)
        let clientText = try String(contentsOf: clientURL, encoding: .utf8)
        let settings = try settings(
            serverConfiguration: serverText,
            clientConfiguration: clientText,
            endpoint: endpoint
        )
        return (settings, clientURL)
    }

    func hostConfiguration(settings: WireGuardSettings) -> String {
        guard settings.hasKeyMaterial else {
            return """
            # Select a VM asset folder that contains wireguard/\(clientConfigurationFileName).
            """
        }

        let endpoint = settings.endpoint ?? "<waiting-for-RTPVM_WG_ENDPOINT>"
        return """
        [Interface]
        PrivateKey = \(settings.clientPrivateKey)
        Address = \(settings.hostTunnelAddress)
        MTU = \(settings.mtu)

        [Peer]
        PublicKey = \(settings.serverPublicKey)
        AllowedIPs = \(settings.allowedIPs)
        Endpoint = \(endpoint)
        PersistentKeepalive = \(settings.persistentKeepalive)
        """
    }

    private func settings(
        serverConfiguration: String,
        clientConfiguration: String,
        endpoint: String?
    ) throws -> WireGuardSettings {
        let server = parse(configuration: serverConfiguration)
        let client = parse(configuration: clientConfiguration)

        let serverInterface = try requiredSection("Interface", in: server, file: serverConfigurationFileName)
        let serverPeer = try requiredSection("Peer", in: server, file: serverConfigurationFileName)
        let clientInterface = try requiredSection("Interface", in: client, file: clientConfigurationFileName)
        let clientPeer = try requiredSection("Peer", in: client, file: clientConfigurationFileName)

        var resolvedEndpoint = endpoint
        if resolvedEndpoint == nil,
           let generatedEndpoint = clientPeer["Endpoint"],
           !generatedEndpoint.hasPrefix("<") {
            resolvedEndpoint = generatedEndpoint
        }

        return WireGuardSettings(
            serverPrivateKey: try requiredValue("PrivateKey", in: serverInterface, file: serverConfigurationFileName),
            serverPublicKey: try requiredValue("PublicKey", in: clientPeer, file: clientConfigurationFileName),
            clientPrivateKey: try requiredValue("PrivateKey", in: clientInterface, file: clientConfigurationFileName),
            clientPublicKey: try requiredValue("PublicKey", in: serverPeer, file: serverConfigurationFileName),
            endpoint: resolvedEndpoint,
            serverAddress: try requiredValue("Address", in: serverInterface, file: serverConfigurationFileName),
            hostTunnelAddress: try requiredValue("Address", in: clientInterface, file: clientConfigurationFileName),
            hostPeerAllowedIP: try requiredValue("AllowedIPs", in: serverPeer, file: serverConfigurationFileName),
            listenPort: try requiredInt("ListenPort", in: serverInterface, file: serverConfigurationFileName),
            mtu: try requiredInt("MTU", in: clientInterface, file: clientConfigurationFileName),
            dnsServers: commaSeparatedValues("DNS", in: clientInterface),
            persistentKeepalive: try requiredInt("PersistentKeepalive", in: clientPeer, file: clientConfigurationFileName),
            allowedIPs: try requiredValue("AllowedIPs", in: clientPeer, file: clientConfigurationFileName)
        )
    }

    private func parse(configuration: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var currentSection = ""

        for rawLine in configuration.split(whereSeparator: \.isNewline) {
            let line = rawLine
                .split(separator: "#", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard !line.isEmpty, !line.hasPrefix(";") else {
                continue
            }

            if line.hasPrefix("["), line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast())
                if sections[currentSection] == nil {
                    sections[currentSection] = [:]
                }
                continue
            }

            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            sections[currentSection, default: [:]][key] = value
        }

        return sections
    }

    private func requiredSection(
        _ section: String,
        in configuration: [String: [String: String]],
        file: String
    ) throws -> [String: String] {
        guard let values = configuration[section] else {
            throw WireGuardConfigurationError.missingField("\(file) [\(section)]")
        }

        return values
    }

    private func requiredValue(
        _ key: String,
        in section: [String: String],
        file: String
    ) throws -> String {
        guard let value = section[key], !value.isEmpty else {
            throw WireGuardConfigurationError.missingField("\(file) \(key)")
        }

        return value
    }

    private func requiredInt(
        _ key: String,
        in section: [String: String],
        file: String
    ) throws -> Int {
        let value = try requiredValue(key, in: section, file: file)
        guard let integer = Int(value) else {
            throw WireGuardConfigurationError.invalidInteger("\(file) \(key)", value)
        }

        return integer
    }

    private func commaSeparatedValues(
        _ key: String,
        in section: [String: String]
    ) -> [String] {
        guard let value = section[key] else {
            return []
        }

        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private enum WireGuardConfigurationError: LocalizedError {
    case missingField(String)
    case invalidInteger(String, String)

    var errorDescription: String? {
        switch self {
        case .missingField(let field):
            return "Missing WireGuard configuration field: \(field)."
        case .invalidInteger(let field, let value):
            return "Invalid WireGuard configuration integer for \(field): \(value)."
        }
    }
}
