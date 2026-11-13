import Foundation

/// The rules for a Linux machine's folders from Files, with no UIKit and no engine, so tests/test_folder_policy.swift
/// can check them: names, slots in the engine's table, states, modes, the texts, and where an export lands.
enum FolderPolicy {
    /// The owner's decision 4; the engine's table has as many (HV_FS_MAX_FOLDERS).
    static let maxFolders = 8
    static let maxNameBytes = 64

    /// A name the guest can use as /media/henge/<name>: one path part, no leading dot (.henge-folders is the host's),
    /// no control characters, at most 64 bytes of UTF-8, and none that another folder has ("Name 2").
    static func safeName(_ raw: String, taken: [String]) -> String {
        var name = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }))
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Folder" }
        let base = fit(name, bytes: maxNameBytes)
        guard taken.contains(base) else { return base }
        for n in 2... {
            let suffix = " \(n)"
            let candidate = fit(name, bytes: maxNameBytes - suffix.utf8.count) + suffix
            if !taken.contains(candidate) { return candidate }
        }
        return base
    }

    /// The longest start of s in that many bytes, cut between characters.
    private static func fit(_ s: String, bytes: Int) -> String {
        var out = ""
        for c in s {
            if out.utf8.count + String(c).utf8.count > bytes { break }
            out.append(c)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// The engine's mode (HV_FS_RO, HV_FS_COW, HV_FS_RW).
    static func engineMode(_ mode: SharedFolder.Mode) -> Int32 {
        switch mode {
        case .readOnly: return 0
        case .copyOnWrite: return 1
        case .readWrite: return 2
        }
    }

    static func title(_ mode: SharedFolder.Mode) -> String {
        switch mode {
        case .readWrite: return "Read-write"
        case .copyOnWrite: return "Copy-on-write"
        case .readOnly: return "Read-only"
        }
    }

    static func detail(_ mode: SharedFolder.Mode) -> String {
        switch mode {
        case .readWrite: return "Linux changes the folder in Files."
        case .copyOnWrite: return "Linux's changes stay on the machine's disk. The folder in Files does not change."
        case .readOnly: return "Linux can read the folder but not change it."
        }
    }

    /// A slot (the engine's index) for each folder: a folder keeps its slot while the session runs, so the guest's
    /// open files stay good; a new one takes the lowest free slot. More than maxFolders get none.
    static func slots(for ids: [UUID], keeping old: [UUID: Int]) -> [UUID: Int] {
        var out = old.filter { ids.contains($0.key) && (0..<maxFolders).contains($0.value) }
        for id in ids where out[id] == nil {
            let used = Set(out.values)
            guard let free = (0..<maxFolders).first(where: { !used.contains($0) }) else { break }
            out[id] = free
        }
        return out
    }

    /// A folder in a session.
    enum State: Equatable {
        /// In the guest at /media/henge/<name>.
        case ready
        /// In the guest's table, but everything in it gives EIO until it is back (moved away, a drive pulled out).
        case unavailable
        /// The bookmark did not resolve: the guest sees it as unavailable until it is picked again.
        case pickAgain
    }

    /// What a bookmark gave at session start.
    enum Resolution: Equatable {
        case resolved(path: String, stale: Bool)
        case failed
    }

    static func state(_ resolution: Resolution, reachable: Bool) -> State {
        switch resolution {
        case .failed: return .pickAgain
        case .resolved: return reachable ? .ready : .unavailable
        }
    }

    /// The state settings shows: the session's while this machine runs, else only what the last session found.
    static func shownState(running: State?, lost: Bool?) -> State? {
        if let running { return running }
        return lost == true ? .pickAgain : nil
    }

    static func label(_ state: State) -> String {
        switch state {
        case .ready: return "Ready"
        case .unavailable: return "Unavailable"
        case .pickAgain: return "Pick Again"
        }
    }

    /// A stale bookmark still works this time, but must be made again from the new URL and saved.
    static func needsNewBookmark(_ resolution: Resolution) -> Bool {
        if case .resolved(_, true) = resolution { return true }
        return false
    }

    /// Resolves a bookmark with resolve (URL(resolvingBookmarkData:...) in the app), and makes a new one when it is
    /// stale. A new bookmark that fails is no new bookmark: the old one still resolves.
    static func resolve(_ bookmark: Data, resolve: (Data) throws -> (URL, Bool), remake: (URL) throws -> Data)
        -> (Resolution, URL?, Data?) {
        guard let (url, stale) = try? resolve(bookmark) else { return (.failed, nil, nil) }
        let r = Resolution.resolved(path: url.path, stale: stale)
        return (r, url, stale ? try? remake(url) : nil)
    }

    static func unreachableNotice(_ name: String) -> String {
        "Henge cannot reach \(name). Pick it again in the machine's settings."
    }

    static func downloadingNotice(_ file: String) -> String { "Downloading \(file)…" }

    /// Once for each folder and each session.
    struct Notices {
        private var shown = Set<UUID>()
        mutating func first(_ id: UUID) -> Bool { shown.insert(id).inserted }
        mutating func reset() { shown.removeAll() }
    }

    /// Asks before a change of mode that hides what Linux did: Copy-on-write's changes stay in its layer, and the
    /// folder then shows the original.
    static func modeChangeWarning(from old: SharedFolder.Mode, to new: SharedFolder.Mode) -> String? {
        guard old == .copyOnWrite, new != .copyOnWrite else { return nil }
        return "Linux then sees the folder in Files as it is, without the changes it made in Copy-on-write. They stay on the machine's disk, and come back if you choose Copy-on-write again. Export them first to keep them in Files."
    }

    static func removeMessage(_ folder: SharedFolder) -> String {
        folder.mode == .copyOnWrite
            ? "Linux no longer sees it. The changes Linux made stay on the machine's disk: discard them first to free the space, or remove them later with henge-files reset."
            : "Linux no longer sees it. The folder stays in Files."
    }

    static let discardMessage = "The changes Linux made to this folder are deleted from the machine's disk, and Linux sees the folder in Files as it is. This cannot be undone."

    /// Where a folder is, for settings: the part a person knows from Files.
    static func displayPath(_ path: String, appDocuments: String? = nil) -> String {
        let parts = path.split(separator: "/").map(String.init)
        func after(_ marker: [String]) -> [String]? {
            guard marker.count <= parts.count else { return nil }
            for i in 0...(parts.count - marker.count) where Array(parts[i..<i + marker.count]) == marker {
                return Array(parts[(i + marker.count)...])
            }
            return nil
        }
        let shown: [String]
        if let docs = appDocuments, path == docs || path.hasPrefix(docs + "/") {
            shown = ["Henge"] + path.dropFirst(docs.count).split(separator: "/").map(String.init)
        } else if let rest = after(["Mobile Documents", "com~apple~CloudDocs"]) {
            shown = ["iCloud Drive"] + rest
        } else if let rest = after(["Mobile Documents"]), let app = rest.first {
            shown = ["iCloud Drive", app.split(separator: "~").last.map(String.init) ?? app] + rest.dropFirst()
        } else if let rest = after(["File Provider Storage"]) {
            shown = ["On My iPhone"] + rest
        } else if let rest = after(["LiveFiles", "com.apple.filesystems.userfsd"]) {
            shown = rest
        } else {
            shown = Array(parts.suffix(2))
        }
        return shown.joined(separator: " › ")
    }

    /// Whether the app coordinates opens and writes (HV_FS_PROVIDER): iCloud Drive and File Provider storage.
    /// A folder in Henge's own container or on a drive is plain files.
    static func isProvider(path: String, ubiquitous: Bool) -> Bool {
        ubiquitous || path.contains("/Mobile Documents/") || path.contains("/File Provider Storage/")
    }

    /// The helper's answer to Export Changes: its folder below the Shared folder, then what it has. nil for a path
    /// that is not in Exports.
    static func exportLocation(_ answer: String, shared: URL) -> (url: URL, summary: String)? {
        let lines = answer.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let rel = lines.first else { return nil }
        let parts = rel.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "Exports", !parts[1].hasPrefix("."), !parts.contains("..") else { return nil }
        let url = parts.reduce(shared) { $0.appendingPathComponent($1, isDirectory: true) }
        return (url, lines.count > 1 ? lines[1] : "")
    }

    /// A URL that opens Files at a folder in Henge's Documents.
    static func filesURL(_ folder: URL) -> URL? {
        var c = URLComponents()
        c.scheme = "shareddocuments"
        c.host = "" // shareddocuments:///path, as Files writes it
        c.path = folder.path
        return c.url
    }

    /// What settings says about adding a folder.
    static func addNote(count: Int, running: Bool, device: Bool) -> String? {
        if count >= maxFolders { return "A machine can have \(maxFolders) folders." }
        if running && !device { return "This machine started with no folders, so a folder added now shows in Linux after it restarts." }
        return nil
    }
}
