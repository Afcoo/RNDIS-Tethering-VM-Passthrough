/*
Copyright (C) 2026 Afcoo.
*/

import AppKit
import SwiftTerm
import SwiftUI

struct ConsoleView: View {
    @EnvironmentObject private var store: TetheringStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderView(title: "VM Console", subtitle: "VM serial terminal - \(store.runtimeState.title)", systemImage: "terminal")

            HStack {
                Button {
                    store.clearConsole()
                } label: {
                    Label("Clear", systemImage: "trash")
                }

                Spacer()
            }

            SwiftTermConsoleView(
                outputData: store.consoleOutputData,
                outputSequence: store.consoleOutputSequence,
                resetSequence: store.consoleResetSequence,
                isInputEnabled: store.canSendConsoleInput,
                sendInput: { data in
                    store.sendConsoleBytes(data)
                }
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(20)
        .navigationTitle("VM Console")
    }
}

private struct SwiftTermConsoleView: NSViewRepresentable {
    let outputData: Data
    let outputSequence: Int
    let resetSequence: Int
    let isInputEnabled: Bool
    let sendInput: @MainActor (Data) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(sendInput: sendInput)
    }

    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let terminalView = SwiftTerm.TerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 540), font: font)
        let foreground = NSColor(calibratedRed: 0.86, green: 0.90, blue: 0.86, alpha: 1)
        let background = NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.07, alpha: 1)

        terminalView.terminalDelegate = context.coordinator
        terminalView.autoresizingMask = [.width, .height]
        terminalView.nativeForegroundColor = foreground
        terminalView.nativeBackgroundColor = background
        terminalView.layer?.backgroundColor = background.cgColor
        terminalView.caretColor = .systemGreen
        terminalView.optionAsMetaKey = true
        terminalView.allowMouseReporting = true
        terminalView.backspaceSendsControlH = false
        terminalView.terminal.changeHistorySize(4_000)

        return terminalView
    }

    func updateNSView(_ terminalView: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.isInputEnabled = isInputEnabled
        terminalView.terminalDelegate = context.coordinator

        if context.coordinator.lastResetSequence != resetSequence {
            reset(terminalView)
            context.coordinator.lastResetSequence = resetSequence
            context.coordinator.lastOutputByteCount = 0
            context.coordinator.lastOutputSequence = 0
            context.coordinator.didRequestInitialFocus = false
        }

        if outputData.count < context.coordinator.lastOutputByteCount ||
            outputSequence < context.coordinator.lastOutputSequence {
            reset(terminalView)
            context.coordinator.lastOutputByteCount = 0
            context.coordinator.lastOutputSequence = 0
        }

        if outputData.count > context.coordinator.lastOutputByteCount {
            let newBytes = Array(outputData.dropFirst(context.coordinator.lastOutputByteCount))
            terminalView.feed(byteArray: newBytes[...])
            context.coordinator.lastOutputByteCount = outputData.count
            context.coordinator.lastOutputSequence = outputSequence
        }

        if isInputEnabled, !context.coordinator.didRequestInitialFocus {
            context.coordinator.didRequestInitialFocus = true
            DispatchQueue.main.async {
                terminalView.window?.makeFirstResponder(terminalView)
            }
        }
    }

    private func reset(_ terminalView: SwiftTerm.TerminalView) {
        terminalView.feed(text: "\u{1B}c\u{1B}[3J\u{1B}[2J\u{1B}[H")
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var isInputEnabled = false
        var lastOutputByteCount = 0
        var lastOutputSequence = 0
        var lastResetSequence = -1
        var didRequestInitialFocus = false

        private let sendInput: @MainActor (Data) -> Void

        init(sendInput: @escaping @MainActor (Data) -> Void) {
            self.sendInput = sendInput
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            guard isInputEnabled else {
                return
            }

            let payload = Data(data)
            Task { @MainActor [sendInput] in
                sendInput(payload)
            }
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
        func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { nil }
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
