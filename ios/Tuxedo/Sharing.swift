import SwiftUI
import UIKit

/// What a running guest shares with this device: the Shared folder in Files, and the clipboard. The clipboard
/// follows through a small helper: henge-clipboard in a Debian desktop (host/share.c).
enum Sharing {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Shared", isDirectory: true)
    }

    /// Before a machine starts.
    static func prepare() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A Unix socket's path can't be long, so the short temporary folder.
        let socket = (NSTemporaryDirectory() as NSString).appendingPathComponent("s.sock")
        tux_vm_share(folder.path, socket)
    }

    /// The helper asks the server for news at most 25 s apart.
    static var helperRunning: Bool {
        let seen = tux_share_helper_seen()
        return seen >= 0 && seen < 40
    }

    /// What is copied in the guest is copied here too. The other way needs the system's paste button: iOS
    /// asks for permission whenever an app reads the clipboard on its own.
    static func followGuestClipboard() async {
        while !Task.isCancelled {
            if let text = tux_share_take_clipboard() {
                UIPasteboard.general.string = String(cString: text)
                free(text)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// What the guest pastes with: terminals want Shift as well.
    enum PasteKeys: String {
        case control, controlShift

        static let storageKey = "henge.linux.pasteKeys"
    }

    /// Text from this device, pasted at the guest's cursor. Without the helper it is typed, as far as the keyboard can.
    /// The guest's helper (henge-clipboard) runs on a Linux desktop only: on the console the text goes to the console.
    static func paste(_ text: String, console: Bool = false, keys: PasteKeys = .control) {
        Task { @MainActor in
            if console {
                let bytes = Array(text.utf8)
                bytes.withUnsafeBufferPointer { tux_vm_console_write($0.baseAddress, $0.count) }
            } else if helperRunning {
                tux_share_set_clipboard(text)
                try? await Task.sleep(nanoseconds: 800_000_000) // for the helper to put it on the guest's clipboard
                if keys == .controlShift {
                    tux_vm_key(Keys.control, 1)
                    tux_vm_key(Keys.shift, 1)
                    Keys.type("v")
                    tux_vm_key(Keys.shift, 0)
                    tux_vm_key(Keys.control, 0)
                } else {
                    Keys.chord(Keys.control, "v")
                }
            } else {
                await Keys.typeSlowly(text)
            }
        }
    }
}
