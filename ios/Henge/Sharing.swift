import SwiftUI
import UIKit

/// What a running guest shares with this device: the Shared folder in Files, and the clipboard. The clipboard
/// follows through a small helper: henge-clipboard in a Debian desktop (host/share.c).
enum Sharing {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Shared", isDirectory: true)
    }

    static let setUpCommand = "curl -s http://10.0.2.4/.henge/install | sh"
    /// Less background work and drawing in macOS (host/share.c, lighten_script), and back.
    static let lightenCommand = "curl -s http://10.0.2.4/.henge/lighten | sh"
    static let unlightenCommand = "curl -s http://10.0.2.4/.henge/unlighten | sh"

    /// Before a Mac starts.
    static func prepare() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A Unix socket's path can't be long, so the short temporary folder.
        let socket = (NSTemporaryDirectory() as NSString).appendingPathComponent("s.sock")
        henge_vm_share(folder.path, socket)
    }

    /// The helper asks the server for news at most 25 s apart.
    static var helperRunning: Bool {
        let seen = henge_share_helper_seen()
        return seen >= 0 && seen < 40
    }

    /// What is copied on the Mac is copied here too. The other way needs the system's paste button: iOS
    /// asks for permission whenever an app reads the clipboard on its own.
    static func followMacClipboard() async {
        while !Task.isCancelled {
            if let text = henge_share_take_clipboard() {
                UIPasteboard.general.string = String(cString: text)
                free(text)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// What a Linux guest pastes with: terminals want Shift as well.
    enum PasteKeys: String {
        case control, controlShift

        static let storageKey = "henge.linux.pasteKeys"
    }

    /// Text from this device, pasted at the guest's cursor. Without the helper it is typed, as far as the keyboard can.
    /// A Linux guest's helper (henge-clipboard) runs on the desktop only: on the console the text goes to the console.
    static func paste(_ text: String, guest: GuestKind = .mac, console: Bool = false, keys: PasteKeys = .control) {
        Task { @MainActor in
            if guest == .linux && console {
                let bytes = Array(text.utf8)
                bytes.withUnsafeBufferPointer { henge_vm_console_write($0.baseAddress, $0.count) }
            } else if helperRunning {
                henge_share_set_clipboard(text)
                try? await Task.sleep(nanoseconds: 800_000_000) // for the helper to put it on the guest's clipboard
                if guest == .linux && keys == .controlShift {
                    henge_vm_key(Keys.control, 1)
                    henge_vm_key(Keys.shift, 1)
                    Keys.type("v")
                    henge_vm_key(Keys.shift, 0)
                    henge_vm_key(Keys.control, 0)
                } else {
                    Keys.chord(guest == .linux ? Keys.control : Keys.command, "v")
                }
            } else {
                await Keys.typeSlowly(text)
            }
        }
    }

    /// Types the set up command at the Mac's cursor, and stops there: the person using the Mac presses Return.
    /// Henge can't see what has the keyboard, so it must not submit anything by itself. Opening Terminal for them
    /// through Spotlight was tried: when Spotlight was slow the text went to a web search, and it could as easily
    /// have gone to a chat.
    static func typeSetUpCommand() async {
        await Keys.typeSlowly(setUpCommand)
    }
}
