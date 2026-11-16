import SwiftUI
import UIKit
import GameController
import SwiftTerm

/// A Linux guest's serial console: drains the engine's ring into a terminal and sends typed bytes back.
/// One model per session, so the scrollback survives switching to the screen and back.
@MainActor
final class ConsoleModel: NSObject, ObservableObject, TerminalViewDelegate {
    private(set) lazy var terminal: TerminalView = makeTerminal()
    private(set) var cols = 80
    private(set) var rows = 24
    var accessory: UIView?
    /// The newest output as text, for Autopilot's console-wait.
    private(set) var tail = ""
    static weak var active: ConsoleModel?
    private var timer: Timer?
    private var scratch = [UInt8](repeating: 0, count: 8192)

    private func makeTerminal() -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480),
                                font: .monospacedSystemFont(ofSize: Device.isPad ? 13 : 11, weight: .regular))
        view.terminalDelegate = self
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = UIColor(white: 0.86, alpha: 1)
        view.contentInsetAdjustmentBehavior = .never
        view.accessibilityLabel = "Console"
        view.accessibilityHint = "Shows the machine's text output. Type to send keys to it."
        accessory = view.inputAccessoryView
        return view
    }

    /// A new machine starts with an empty terminal.
    func reset() {
        discardPending()
        tail = ""
        terminal.feed(text: "\u{1b}c\u{1b}[3J")
    }

    func start() {
        stop()
        Self.active = self
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drain() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func discardPending() {
        while scratch.withUnsafeMutableBufferPointer({ tux_vm_console_read($0.baseAddress, $0.count) }) > 0 {}
    }

    private func drain() {
        var chunk: [UInt8] = []
        while chunk.count < 65536 { // a cap so a flood cannot hold the main thread
            let n = scratch.withUnsafeMutableBufferPointer { tux_vm_console_read($0.baseAddress, $0.count) }
            if n == 0 { break }
            chunk.append(contentsOf: scratch[0..<n])
        }
        if !chunk.isEmpty {
            terminal.feed(byteArray: chunk[...])
            tail = String((tail + String(decoding: chunk, as: UTF8.self)).suffix(16384))
        }
    }

    /// The serial line has no window size; this tells the guest ours. Only on request: it types into whatever runs.
    func fit() {
        write(Array("stty rows \(rows) cols \(cols)\n".utf8))
    }

    private func write(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { tux_vm_console_write($0.baseAddress, $0.count) }
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) { write(Array(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { cols = newCols; rows = newRows }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// The terminal on screen. It holds the keyboard while it shows; with no soft keyboard asked for, a hardware
/// keyboard still types into it.
struct ConsoleView: UIViewRepresentable {
    let model: ConsoleModel
    @Binding var typing: Bool

    func makeUIView(context: Context) -> Host { Host(model: model) }

    func updateUIView(_ host: Host, context: Context) {
        host.onTap = { typing = true }
        host.onHide = { typing = false }
        host.apply(typing: typing)
    }

    static func dismantleUIView(_ host: Host, coordinator: ()) { host.release() }

    final class Host: UIView {
        private let model: ConsoleModel
        private let blank = UIView(frame: .zero)
        private var softKeyboard: Bool?
        private var hiding: NSObjectProtocol?
        var onTap: () -> Void = {}
        var onHide: () -> Void = {}

        init(model: ConsoleModel) {
            self.model = model
            super.init(frame: .zero)
            backgroundColor = .black
            clipsToBounds = true
            let term = model.terminal
            term.removeFromSuperview()
            addSubview(term)
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            tap.cancelsTouchesInView = false
            addGestureRecognizer(tap)
            hiding = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardHid() }
            }
        }

        required init?(coder: NSCoder) { fatalError("made in code") }

        deinit {
            if let hiding { NotificationCenter.default.removeObserver(hiding) }
        }

        @objc private func tapped() { onTap() }

        /// iPadOS's hide-keyboard key closes it without asking the app.
        private func keyboardHid() {
            guard softKeyboard == true, let window, window.rootViewController?.presentedViewController == nil else { return }
            onHide()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let term = model.terminal
            if term.frame != bounds { term.frame = bounds }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            focus()
        }

        func apply(typing: Bool) {
            if softKeyboard != typing {
                softKeyboard = typing
                let term = model.terminal
                term.inputView = typing ? nil : blank
                term.inputAccessoryView = typing ? model.accessory : nil
                if term.isFirstResponder { term.reloadInputViews() }
            }
            focus()
        }

        /// Called often, which also takes the keyboard back after a sheet has had it.
        private func focus() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window,
                      window.rootViewController?.presentedViewController == nil else { return }
                let term = self.model.terminal
                if !term.isFirstResponder { term.becomeFirstResponder() }
            }
        }

        func release() {
            let term = model.terminal
            if term.isFirstResponder { term.resignFirstResponder() }
            if term.superview === self { term.removeFromSuperview() }
            NotificationCenter.default.post(name: .consoleReleasedKeys, object: nil)
        }
    }
}

extension Notification.Name {
    /// The console let go of the keys: the key listener takes them.
    static let consoleReleasedKeys = Notification.Name("tux.consoleReleasedKeys")
}
