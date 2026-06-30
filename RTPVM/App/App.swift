/*
Copyright (C) 2026 Afcoo.
*/

import AppKit
import SwiftUI

@main
struct App: SwiftUI.App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = TetheringStore()

    var body: some Scene {
        WindowGroup("RNDIS Tethering VM Passthrough", id: "main") {
            ContentView()
                .environmentObject(store)
                .onAppear {
                    appDelegate.store = store
                    store.startAccessoryMonitoringOnLaunch()
                }
                .frame(minWidth: 980, minHeight: 680)
        }
        .commands {
            CommandMenu("VM") {
                Button("Start VM") {
                    store.startVirtualMachine()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!store.canStartVirtualMachine)

                Button("Stop VM") {
                    store.stopVirtualMachine()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!store.canStopVirtualMachine)
            }
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: TetheringStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store?.prepareForApplicationTermination()
        return .terminateNow
    }
}
