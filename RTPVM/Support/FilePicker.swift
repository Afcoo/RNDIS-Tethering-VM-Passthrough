/*
Copyright (C) 2026 Afcoo.
*/

import AppKit
import Foundation

enum FilePicker {
    @MainActor
    static func chooseFile(title: String, initialURL: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        if let initialURL {
            panel.directoryURL = initialURL.deletingLastPathComponent()
            panel.nameFieldStringValue = initialURL.lastPathComponent
        }

        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func chooseDirectory(title: String, initialURL: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.resolvesAliases = true

        if let initialURL {
            panel.directoryURL = initialURL.hasDirectoryPath ? initialURL : initialURL.deletingLastPathComponent()
        }

        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func chooseSaveFile(title: String, defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true

        return panel.runModal() == .OK ? panel.url : nil
    }
}
