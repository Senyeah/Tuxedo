import Foundation

// FM8: a Linux machine's folders from Files (ios/Henge/FolderPolicy.swift, SharedFolder in MachineModel.swift):
// names, slots, bookmarks that are stale or gone, states, modes, the texts, where an export lands, and what an
// export of the machine leaves out. Pure: no UIKit, no engine.
@main
struct FolderPolicyTests {
    static var failures = 0

    static func check(_ what: String, _ ok: Bool) {
        if !ok {
            print("FAIL \(what)")
            failures += 1
        }
    }

    static func main() throws {
        names()
        slots()
        try bookmarks()
        states()
        modes()
        places()
        exports()
        try model()
        if failures > 0 { exit(1) }
        print("folder policy: ok")
    }

    static func names() {
        let n = FolderPolicy.safeName
        check("a plain name stays", n("Projects", []) == "Projects")
        check("a slash", n("a/b", []) == "a-b")
        check("leading dots", n("..hidden", []) == "hidden")
        check("the host's own file", n(".henge-folders", []) == "henge-folders")
        check("control characters", n("a\u{0}b\nc\u{7f}", []) == "abc")
        check("spaces at the ends", n("  Docs  ", []) == "Docs")
        check("nothing left", n("...", []) == "Folder" && n("", []) == "Folder" && n("/", []) == "-")
        check("a second one", n("Docs", ["Docs"]) == "Docs 2")
        check("a third one", n("Docs", ["Docs", "Docs 2"]) == "Docs 3")
        check("case is the guest's: another name", n("docs", ["Docs"]) == "docs")
        let long = String(repeating: "a", count: 70)
        check("64 bytes", n(long, []).utf8.count == 64)
        check("64 bytes with a number", n(long, [String(repeating: "a", count: 64)]) == String(repeating: "a", count: 62) + " 2")
        let wide = String(repeating: "é", count: 40) // 80 bytes
        let cut = n(wide, [])
        check("cut between characters", cut.utf8.count <= 64 && cut == String(repeating: "é", count: 32))
        check("NFC and NFD stay as given", n("Caf\u{e9}", []) == "Caf\u{e9}" && n("Cafe\u{301}", []).unicodeScalars.count == 5)
        check("a dot inside stays", n("v1.2", []) == "v1.2")
    }

    static func slots() {
        let a = UUID(), b = UUID(), c = UUID()
        let first = FolderPolicy.slots(for: [a, b], keeping: [:])
        check("first slots", first == [a: 0, b: 1])
        let removed = FolderPolicy.slots(for: [b], keeping: first)
        check("a folder keeps its slot when another goes", removed == [b: 1])
        let added = FolderPolicy.slots(for: [b, c], keeping: removed)
        check("a new folder takes the lowest free slot", added == [b: 1, c: 0])
        let many = (0..<10).map { _ in UUID() }
        let full = FolderPolicy.slots(for: many, keeping: [:])
        check("at most 8", full.count == 8 && Set(full.values) == Set(0..<8) && full[many[8]] == nil)
        check("a bad old slot is dropped", FolderPolicy.slots(for: [a], keeping: [a: 9]) == [a: 0])
    }

    static func bookmarks() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("folder-policy-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let real = try dir.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        func resolve(_ d: Data) throws -> (URL, Bool) {
            var stale = false
            let url = try URL(resolvingBookmarkData: d, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            return (url, stale)
        }
        let made = { (u: URL) throws -> Data in try u.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) }
        let (r, url, again) = FolderPolicy.resolve(real, resolve: resolve, remake: made)
        check("a real bookmark resolves", url?.standardizedFileURL.resolvingSymlinksInPath().path == dir.resolvingSymlinksInPath().path)
        check("fresh: no new bookmark", again == nil && !FolderPolicy.needsNewBookmark(r))

        let (sr, _, sNew) = FolderPolicy.resolve(real, resolve: { (try resolve($0).0, true) }, remake: { _ in Data([1, 2, 3]) })
        check("stale: a new bookmark to save", FolderPolicy.needsNewBookmark(sr) && sNew == Data([1, 2, 3]))
        let (fr, _, fNew) = FolderPolicy.resolve(real, resolve: { (try resolve($0).0, true) }, remake: { _ in throw CocoaError(.fileReadUnknown) })
        check("stale, and no new one: the old one is kept", FolderPolicy.needsNewBookmark(fr) && fNew == nil)
        let (gone, gURL, _) = FolderPolicy.resolve(Data("not a bookmark".utf8), resolve: resolve, remake: made)
        check("garbage: pick again", gone == .failed && gURL == nil && FolderPolicy.state(gone, reachable: true) == .pickAgain)
    }

    static func states() {
        let ok = FolderPolicy.Resolution.resolved(path: "/x", stale: false)
        check("resolved and there", FolderPolicy.state(ok, reachable: true) == .ready)
        check("resolved, not there", FolderPolicy.state(ok, reachable: false) == .unavailable)
        check("settings: the session's state wins", FolderPolicy.shownState(running: .ready, lost: true) == .ready)
        check("settings: lost last time", FolderPolicy.shownState(running: nil, lost: true) == .pickAgain)
        check("settings: nothing known", FolderPolicy.shownState(running: nil, lost: nil) == nil)
        check("labels", FolderPolicy.label(.pickAgain) == "Pick Again" && FolderPolicy.label(.unavailable) == "Unavailable")
        var notices = FolderPolicy.Notices()
        let id = UUID()
        check("a notice once for each folder", notices.first(id) && !notices.first(id) && notices.first(UUID()))
        notices.reset()
        check("and again in the next session", notices.first(id))
        check("the unreachable notice", FolderPolicy.unreachableNotice("Projects") == "Henge cannot reach Projects. Pick it again in Details, Folders.")
        check("the download notice", FolderPolicy.downloadingNotice("a.pdf") == "Downloading a.pdf…")
        check("add: at most 8", FolderPolicy.addNote(count: 8, running: false, device: false) != nil)
        check("add: no device means a restart", FolderPolicy.addNote(count: 0, running: true, device: false)?.contains("restarts") == true)
        check("add: fine", FolderPolicy.addNote(count: 1, running: true, device: true) == nil && FolderPolicy.addNote(count: 0, running: false, device: false) == nil)
    }

    static func modes() {
        check("Read-write is the default", SharedFolder(name: "a", bookmark: Data()).mode == .readWrite)
        check("Read-write first in the choices", SharedFolder.Mode.allCases.first == .readWrite)
        check("engine modes", FolderPolicy.engineMode(.readOnly) == 0 && FolderPolicy.engineMode(.copyOnWrite) == 1 && FolderPolicy.engineMode(.readWrite) == 2)
        check("leaving Copy-on-write asks", FolderPolicy.modeChangeWarning(from: .copyOnWrite, to: .readWrite) != nil
              && FolderPolicy.modeChangeWarning(from: .copyOnWrite, to: .readOnly) != nil)
        check("other changes do not", FolderPolicy.modeChangeWarning(from: .readWrite, to: .copyOnWrite) == nil
              && FolderPolicy.modeChangeWarning(from: .readOnly, to: .readWrite) == nil
              && FolderPolicy.modeChangeWarning(from: .copyOnWrite, to: .copyOnWrite) == nil)
        var cow = SharedFolder(name: "a", bookmark: Data())
        cow.mode = .copyOnWrite
        check("remove: Copy-on-write says where the changes are", FolderPolicy.removeMessage(cow).contains("machine's disk"))
        check("remove: Read-write does not", !FolderPolicy.removeMessage(SharedFolder(name: "a", bookmark: Data())).contains("disk"))
    }

    static func places() {
        let p = FolderPolicy.displayPath
        check("iCloud Drive", p("/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Projects/web", nil) == "iCloud Drive › Projects › web")
        check("an app's iCloud folder", p("/private/var/mobile/Library/Mobile Documents/iCloud~com~example~Notes/Documents", nil) == "iCloud Drive › Notes › Documents")
        check("On My iPhone", p("/private/var/mobile/Containers/Shared/AppGroup/ABC/File Provider Storage/Music", nil) == "On My iPhone › Music")
        check("a drive", p("/private/var/mobile/Library/LiveFiles/com.apple.filesystems.userfsd/USB/Photos", nil) == "USB › Photos")
        check("Henge's own", p("/var/mobile/Containers/Data/Application/X/Documents/Shared/src", "/var/mobile/Containers/Data/Application/X/Documents") == "Henge › Shared › src")
        check("anything else: the last two parts", p("/Users/me/tmp/Folder", nil) == "tmp › Folder")
        check("provider: iCloud", FolderPolicy.isProvider(path: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/a", ubiquitous: false))
        check("provider: File Provider storage", FolderPolicy.isProvider(path: "/x/File Provider Storage/a", ubiquitous: false))
        check("provider: ubiquitous", FolderPolicy.isProvider(path: "/x", ubiquitous: true))
        check("local: Henge's own and drives", !FolderPolicy.isProvider(path: "/var/mobile/Containers/Data/Application/X/Documents/a", ubiquitous: false))
    }

    static func exports() {
        let shared = URL(fileURLWithPath: "/docs/Shared", isDirectory: true)
        let e = FolderPolicy.exportLocation("Exports/Docs-14-11-2026-1200\n3 files, 1 deletions, 0 links", shared: shared)
        check("export: the folder", e?.url.path == "/docs/Shared/Exports/Docs-14-11-2026-1200")
        check("export: the summary", e?.summary == "3 files, 1 deletions, 0 links")
        check("export: no way out", FolderPolicy.exportLocation("Exports/../../x\n", shared: shared) == nil
              && FolderPolicy.exportLocation("../x\n", shared: shared) == nil
              && FolderPolicy.exportLocation("Exports/a/b\n", shared: shared) == nil
              && FolderPolicy.exportLocation("Other/x\n", shared: shared) == nil
              && FolderPolicy.exportLocation("Exports/..\n", shared: shared) == nil
              && FolderPolicy.exportLocation("", shared: shared) == nil)
        let answer = "Exports/Docs-1\n2 files, 1 deletions, 0 links\nfiles=3 bytes=120"
        check("export: the summary, not the counts", FolderPolicy.exportLocation(answer, shared: shared)?.summary == "2 files, 1 deletions, 0 links")
        let want = FolderPolicy.exportExpected(answer)
        check("export: what to wait for", want?.files == 3 && want?.bytes == 120)
        check("export: an older helper gives no counts", FolderPolicy.exportExpected("Exports/Docs-1\n2 files, 1 deletions, 0 links") == nil
              && FolderPolicy.exportExpected("Exports/Docs-1\nx\nfiles=x bytes=1") == nil)
        if let want {
            let all: [(name: String, size: Int64)] = [("a.txt", 100), ("deletions.txt", 6), (".bashrc", 14)]
            check("export: all there", FolderPolicy.exportArrived(all, expected: want))
            check("export: a file still coming", !FolderPolicy.exportArrived(Array(all.prefix(2)), expected: want))
            check("export: a file not all there", !FolderPolicy.exportArrived([("a.txt", 50), ("deletions.txt", 6), (".bashrc", 14)], expected: want))
            check("export: an upload in its temporary file", !FolderPolicy.exportArrived([("a.txt", 100), ("deletions.txt", 6), (".henge-put-a1", 14)], expected: want))
        }
        check("trash: Recently Deleted", FolderPolicy.isTrash(path: "/private/var/mobile/Library/Mobile Documents/.Trash/Projects")
              && FolderPolicy.isTrash(path: "/x/File Provider Storage/.Trash/Music"))
        check("trash: not a folder with Trash in its name", !FolderPolicy.isTrash(path: "/x/My .Trash things/a") && !FolderPolicy.isTrash(path: "/x/Trash"))
        check("export: a space in the name", FolderPolicy.exportLocation("Exports/My Docs-1", shared: shared)?.url.lastPathComponent == "My Docs-1")
        let files = FolderPolicy.filesURL(URL(fileURLWithPath: "/var/mobile/Documents/Shared/Exports/My Docs-1"))
        check("Files: the shareddocuments scheme", files?.scheme == "shareddocuments")
        check("Files: the path, escaped", files?.absoluteString == "shareddocuments:///var/mobile/Documents/Shared/Exports/My%20Docs-1")
    }

    static func model() throws {
        // A machine from a list written before folders: none.
        let old = """
        [{"id":"11111111-2222-3333-4444-555555555555","name":"Debian","ramMB":4096,
          "diskBytes":17179869184,"added":784000000.5}]
        """
        let list = MachineList.decode(Data(old.utf8), diskExists: { _ in true })!
        check("an old list: no folders", list[0].folders == nil)
        var machine = list[0]
        var f = SharedFolder(name: "Projects", bookmark: Data([9, 8, 7]))
        f.mode = .copyOnWrite
        f.displayPath = "iCloud Drive › Projects"
        f.lost = true
        machine.folders = [f]
        let data = try JSONEncoder().encode([machine])
        let back = MachineList.decode(data, diskExists: { _ in true })!
        check("folders round-trip", back[0].folders == [f])
        check("a list without folders writes none", !String(decoding: try JSONEncoder().encode(list), as: UTF8.self).contains("folders"))
        let info = MachineFolder.exportInfo(machine)
        let infoText = String(decoding: try JSONSerialization.data(withJSONObject: info), as: UTF8.self)
        check("an export of the machine leaves the folders out", info["folders"] == nil && !infoText.contains("bookmark") && !infoText.contains("Projects"))
    }
}
