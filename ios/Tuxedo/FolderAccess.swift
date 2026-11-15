import Foundation
import UIKit

/// The running Linux machine's folders from Files (docs/files-mount-plan.md). The session starts this after its
/// Face ID check and ends it when the machine stops. Access is held for the whole session, in the background with
/// sound too, even with the wallet locked (the owner's decision 6). The rules are FolderPolicy's.
@MainActor
final class FolderSession: ObservableObject {
    static let shared = FolderSession()

    /// The machine whose folders are open, or nil.
    @Published private(set) var machine: UUID?
    @Published private(set) var states: [UUID: FolderPolicy.State] = [:]
    /// A short notice for the session screen.
    @Published var notice: String?
    @Published private(set) var asks: [UUID: Ask] = [:]

    enum Ask: Equatable {
        case exporting, discarding
        case exported(URL, String)
        case discarded
        case failed(String)
    }

    private struct Open {
        var url: URL
        var bookmark: Data
        /// The URL whose security-scoped access is started: it is the one to stop.
        var access: URL?
        var presenter: FolderPresenter?
        /// The engine has the placeholder for it: the real folder must go in again when it is back.
        var placeholder = false
    }

    private var open: [UUID: Open] = [:]
    private var slots: [UUID: Int] = [:]
    private var notices = FolderPolicy.Notices()
    private var watch: Task<Void, Never>?
    private var touches: [UUID: Task<Void, Never>] = [:]
    private var downloads = 0

    /// An empty folder for one that cannot be reached: the guest sees it as unavailable, not gone. One for each
    /// folder, and no one can write in it.
    private static func placeholder(_ id: UUID) -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("tux-unavailable/\(id.uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir)
        return dir
    }

    /// Before a Linux machine boots: the engine's table for tux_vm_boot_linux.
    func start(_ machine: VirtualMachine) {
        end()
        self.machine = machine.id
        notices.reset()
        tux_vm_folders_hook(folderHook, nil)
        apply(machine.folders ?? [])
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.checkReachable()
            }
        }
    }

    /// The machine stopped, or the session closed.
    func end() {
        watch?.cancel()
        watch = nil
        touches.values.forEach { $0.cancel() }
        touches.removeAll()
        for id in Array(open.keys) { close(id) }
        tux_vm_folders_hook(nil, nil)
        tux_vm_folders_clear()
        FolderHooks.shared.clear()
        slots.removeAll()
        states.removeAll()
        asks.removeAll()
        machine = nil
        notice = nil
    }

    /// Settings changed this machine's folders while it runs: they apply at once (a new mode when nothing in the
    /// guest has the folder open).
    func changed(_ machine: VirtualMachine) {
        guard self.machine == machine.id else { return }
        apply(machine.folders ?? [])
    }

    var device: Bool { machine != nil && tux_vm_folders_device() != 0 }

    private func apply(_ list: [SharedFolder]) {
        let ids = list.prefix(FolderPolicy.maxFolders).map(\.id)
        for id in Array(open.keys) where !ids.contains(id) { close(id) }
        for (id, slot) in slots where !ids.contains(id) {
            tux_vm_folder_clear(Int32(slot))
            states[id] = nil
            asks[id] = nil
        }
        slots = FolderPolicy.slots(for: ids, keeping: slots)
        for folder in list.prefix(FolderPolicy.maxFolders) {
            guard let slot = slots[folder.id] else { continue }
            if let o = open[folder.id], o.bookmark != folder.bookmark { close(folder.id) } // picked again
            if open[folder.id] == nil { openFolder(folder) }
            put(folder, slot: slot)
        }
    }

    /// Saves a change to one of this machine's folders.
    private func save(_ id: UUID, _ change: (inout SharedFolder) -> Void) {
        guard let machine else { return }
        Machines.shared.updateFolders(of: machine) { list in
            if let i = list.firstIndex(where: { $0.id == id }) { change(&list[i]) }
        }
    }

    private func openFolder(_ folder: SharedFolder) {
        var scoped = false
        let (resolution, url, newBookmark) = FolderPolicy.resolve(folder.bookmark, resolve: { data in
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            scoped = url.startAccessingSecurityScopedResource() // before a new bookmark, which needs it
            return (url, stale)
        }, remake: { url in
            try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        })
        guard let url else {
            TuxLog.log("folders", "\(folder.name): the bookmark did not resolve: pick it again")
            save(folder.id) { $0.lost = true }
            return
        }
        var bookmark = folder.bookmark
        if let newBookmark {
            bookmark = newBookmark
            save(folder.id) { $0.bookmark = newBookmark }
            TuxLog.log("folders", "\(folder.name): the bookmark was stale: saved a new one")
        }
        if folder.lost == true { save(folder.id) { $0.lost = nil } }
        let presenter = FolderPresenter(url: url, id: folder.id)
        NSFileCoordinator.addFilePresenter(presenter)
        open[folder.id] = Open(url: url, bookmark: bookmark, access: scoped ? url : nil, presenter: presenter)
        if case .resolved = resolution, provider(url) {
            Task.detached { // an older File Provider lists a folder in full only after a coordinated read of it
                var error: NSError?
                NSFileCoordinator(filePresenter: presenter).coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { _ in }
            }
        }
    }

    private func close(_ id: UUID) {
        guard let o = open.removeValue(forKey: id) else { return }
        if let p = o.presenter { NSFileCoordinator.removeFilePresenter(p) }
        o.access?.stopAccessingSecurityScopedResource()
    }

    private func provider(_ url: URL) -> Bool {
        let ubiquitous = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false
        return FolderPolicy.isProvider(path: url.path, ubiquitous: ubiquitous)
    }

    /// The folder into the engine's table; one that cannot be opened is there as unavailable.
    private func put(_ folder: SharedFolder, slot: Int) {
        let mode = FolderPolicy.engineMode(folder.mode)
        let id = folder.id.uuidString
        if let o = open[folder.id] {
            let kind: Int32 = provider(o.url) ? 1 : 0
            if tux_vm_folder_set(Int32(slot), id, folder.name, o.url.path, mode, kind) == 0 {
                let there = reachable(o.url)
                tux_vm_folder_online(Int32(slot), there ? 1 : 0)
                FolderHooks.shared.set(slot, url: o.url, presenter: o.presenter)
                open[folder.id]?.placeholder = false
                setState(folder, FolderPolicy.state(.resolved(path: o.url.path, stale: false), reachable: there))
                return
            }
            if !o.placeholder { TuxLog.log("folders", "\(folder.name): the engine refused it: \(String(cString: strerror(errno)))") }
        }
        if tux_vm_folder_set(Int32(slot), id, folder.name, Self.placeholder(folder.id), mode, 0) == 0 {
            tux_vm_folder_online(Int32(slot), 0)
        }
        open[folder.id]?.placeholder = true
        FolderHooks.shared.set(slot, url: nil, presenter: nil)
        setState(folder, open[folder.id] == nil ? .pickAgain : .unavailable)
    }

    private func reachable(_ url: URL) -> Bool {
        !FolderPolicy.isTrash(path: url.path) && FileManager.default.fileExists(atPath: url.path)
    }

    private func setState(_ folder: SharedFolder, _ state: FolderPolicy.State) {
        let was = states[folder.id]
        states[folder.id] = state
        if state != .ready && was != state && notices.first(folder.id) { notice = FolderPolicy.unreachableNotice(folder.name) }
        if was != nil && was != state { TuxLog.log("folders", "\(folder.name): \(FolderPolicy.label(state))") }
    }

    private var folders: [SharedFolder] {
        guard let machine else { return [] }
        return Machines.shared.all.first { $0.id == machine }?.folders ?? []
    }

    /// A folder that was deleted, or a drive that was pulled out, goes unavailable; when it is back it works again.
    private func checkReachable() {
        for folder in folders {
            guard let o = open[folder.id], let slot = slots[folder.id], let state = states[folder.id], state != .pickAgain else { continue }
            let there = reachable(o.url)
            guard there != (state == .ready) else { continue }
            if o.placeholder {
                put(folder, slot: slot) // the real folder in again, not the placeholder online
                continue
            }
            tux_vm_folder_online(Int32(slot), there ? 1 : 0)
            setState(folder, there ? .ready : .unavailable)
        }
    }

    // MARK: The presenter's news

    /// A move to Recently Deleted is a move too: reachable() then has it unavailable, and a restore brings it back.
    fileprivate func moved(_ id: UUID, to url: URL) {
        guard var o = open[id], let folder = folders.first(where: { $0.id == id }), let slot = slots[id] else { return }
        o.url = url
        // The access started on the old URL may not cover the new place; the bookmark resolves there with its own.
        var stale = false
        if let found = try? URL(resolvingBookmarkData: o.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
            if found.startAccessingSecurityScopedResource() {
                o.access?.stopAccessingSecurityScopedResource()
                o.access = found
            }
            o.url = found
        }
        if !FolderPolicy.isTrash(path: o.url.path) {
            do {
                let data = try o.url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                o.bookmark = data
                save(id) { $0.bookmark = data }
            } catch {
                TuxLog.log("folders", "\(folder.name): no new bookmark after the move: \(error.localizedDescription)")
            }
        }
        open[id] = o
        TuxLog.log("folders", "\(folder.name) moved in Files\(FolderPolicy.isTrash(path: o.url.path) ? " to Recently Deleted" : "")")
        put(folder, slot: slot) // the same folder: the guest's open files stay good
    }

    fileprivate func deleted(_ id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }), let slot = slots[id] else { return }
        tux_vm_folder_online(Int32(slot), 0)
        setState(folder, .unavailable)
    }

    /// Something in a Copy-on-write folder's original changed: the guest remounts it, a second later, once.
    fileprivate func originalChanged(_ id: UUID) {
        guard folders.first(where: { $0.id == id })?.mode == .copyOnWrite, touches[id] == nil else { return }
        touches[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.touches[id] = nil
            if let slot = self.slots[id] { tux_vm_folder_touch(Int32(slot)) }
        }
    }

    fileprivate func downloadStarted(_ file: String) {
        downloads += 1
        notice = FolderPolicy.downloadingNotice(file)
    }

    fileprivate func downloadEnded() {
        downloads = max(downloads - 1, 0)
        if downloads == 0, notice?.hasPrefix("Downloading ") == true { notice = nil }
    }

    // MARK: Export Changes and Discard Changes (FM10)

    /// Only while this machine runs with the device: the guest's helper does the work.
    func canAsk(_ folder: SharedFolder, machine id: UUID) -> Bool {
        machine == id && device && folder.mode == .copyOnWrite && states[folder.id] != nil && !asking(folder.id)
    }

    func asking(_ id: UUID) -> Bool { asks[id] == .exporting || asks[id] == .discarding }

    func export(_ id: UUID) { ask(id, what: 1) }
    func discard(_ id: UUID) { ask(id, what: 2) }

    private func ask(_ id: UUID, what: Int) {
        guard let slot = slots[id] else { return }
        let n = tux_vm_folder_ask(Int32(slot), Int32(what))
        guard n > 0 else {
            asks[id] = .failed("Only a Copy-on-write folder has changes of its own.")
            return
        }
        asks[id] = what == 1 ? .exporting : .discarding
        Task { [weak self] in
            let end = Date().addingTimeInterval(300)
            while Date() < end {
                var ok: Int32 = 0
                var text: UnsafeMutablePointer<CChar>?
                let rc = tux_vm_folder_answered(Int32(slot), n, &ok, &text)
                let answer = text.map { String(cString: $0) } ?? ""
                free(text)
                if rc != 0 {
                    await self?.answered(id, what: what, ok: rc == 1 && ok != 0, text: rc == 1 ? answer : "The machine stopped.")
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                if self?.slots[id] != slot { return }
            }
            tux_vm_folder_ask(Int32(slot), 0)
            await self?.answered(id, what: what, ok: false, text: "Linux did not answer. The machine needs henge-guest 1.8.0 or later (sudo apt install henge-guest).")
        }
    }

    private func answered(_ id: UUID, what: Int, ok: Bool, text: String) async {
        guard ok else {
            asks[id] = .failed(text.replacingOccurrences(of: "henge-files: ", with: ""))
            return
        }
        guard what == 1 else {
            asks[id] = .discarded
            return
        }
        guard let (url, summary) = FolderPolicy.exportLocation(text, shared: Sharing.folder) else {
            asks[id] = .failed("Linux gave an export folder outside Exports: \(text)")
            return
        }
        // The helper answers once its copies are in davfs2's cache; each reaches Files a second after it closes.
        if let want = FolderPolicy.exportExpected(text) {
            var last: Int64 = -1, still = 0
            while true {
                let found = Self.filesBelow(url)
                if FolderPolicy.exportArrived(found, expected: want) { break }
                let bytes = found.reduce(0) { $0 + $1.size }
                still = bytes == last ? still + 1 : 0
                last = bytes
                if still >= 60 { // 30 s with nothing new
                    TuxLog.log("folders", "export to \(url.lastPathComponent): \(found.count) of \(want.files) files, \(bytes) of \(want.bytes) bytes")
                    asks[id] = .failed("Only part of the export reached Files, in Tuxedo, Shared, Exports, \(url.lastPathComponent). Keep Tuxedo open while it exports, then export again.")
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        } else {
            for _ in 0..<60 where !FileManager.default.fileExists(atPath: url.path) { // a helper before 1.8.0's counts
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        TuxLog.log("folders", "exported to \(url.lastPathComponent): \(summary)")
        asks[id] = .exported(url, summary)
    }

    /// (name, size) of each file below dir.
    private static func filesBelow(_ dir: URL) -> [(name: String, size: Int64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walk = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return [] }
        var out: [(name: String, size: Int64)] = []
        for case let file as URL in walk {
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            out.append((file.lastPathComponent, Int64(v.fileSize ?? 0)))
        }
        return out
    }

    func clearAsk(_ id: UUID) { if !asking(id) { asks[id] = nil } }
}

/// What a device worker needs for a folder's hook: no main actor there.
final class FolderHooks: @unchecked Sendable {
    static let shared = FolderHooks()
    private let lock = NSLock()
    private var entries: [Int: (url: URL, presenter: NSFilePresenter?)] = [:]

    func set(_ slot: Int, url: URL?, presenter: NSFilePresenter?) {
        lock.lock()
        entries[slot] = url.map { ($0, presenter) }
        lock.unlock()
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    func get(_ slot: Int) -> (url: URL, presenter: NSFilePresenter?)? {
        lock.lock()
        defer { lock.unlock() }
        return entries[slot]
    }
}

/// The engine calls this for a folder of the File Provider kind (iCloud Drive, another app's), on a device worker.
/// A coordinated read makes the provider fetch a file that is not downloaded; a coordinated write after a written
/// file closes tells the provider and other apps of the change (not verified on a phone: FM1, FM11).
private let folderHook: TuxFolderHook = { _, slot, path, event in
    guard let path, let entry = FolderHooks.shared.get(Int(slot)) else { return 0 }
    let url = entry.url.appendingPathComponent(String(cString: path))
    let coordinator = NSFileCoordinator(filePresenter: entry.presenter) // not our own presenter's news
    var error: NSError?
    if event == 1 {
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &error) { _ in }
        return 0
    }
    let file = url.lastPathComponent
    let shown = MainFlag()
    let slow = DispatchWorkItem { MainActor.assumeIsolated { shown.on = true; FolderSession.shared.downloadStarted(file) } }
    let late = DispatchWorkItem { coordinator.cancel() } // no network: EIO, not a guest that waits for ever
    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: slow)
    DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: late)
    coordinator.coordinate(readingItemAt: url, options: [], error: &error) { _ in }
    late.cancel()
    slow.cancel()
    DispatchQueue.main.async { MainActor.assumeIsolated { if shown.on { FolderSession.shared.downloadEnded() } } } // after slow, if it ran
    guard let error else { return 0 }
    if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
        return 0 // the open gives its own ENOENT
    }
    TuxLog.log("folders", "a coordinated read failed: \(error.domain) \(error.code)")
    return EIO
}

/// Set and read on the main queue only.
private final class MainFlag: @unchecked Sendable { var on = false }

/// Tells the session what Files and other apps do to a folder while the machine runs. Only coordinated changes come
/// here; others show in the guest when its cache times out.
final class FolderPresenter: NSObject, NSFilePresenter {
    private let lock = NSLock()
    private var url: URL
    let id: UUID
    let presentedItemOperationQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return q
    }()

    init(url: URL, id: UUID) {
        self.url = url
        self.id = id
    }

    var presentedItemURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return url
    }

    func presentedItemDidMove(to newURL: URL) {
        lock.lock()
        url = newURL
        lock.unlock()
        let id = id
        DispatchQueue.main.async { MainActor.assumeIsolated { FolderSession.shared.moved(id, to: newURL) } }
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        let id = id
        DispatchQueue.main.async { MainActor.assumeIsolated { FolderSession.shared.deleted(id) } }
        completionHandler(nil)
    }

    private func changed() {
        let id = id
        DispatchQueue.main.async { MainActor.assumeIsolated { FolderSession.shared.originalChanged(id) } }
    }

    func presentedSubitemDidChange(at url: URL) { changed() }
    func presentedSubitemDidAppear(at url: URL) { changed() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { changed() }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        changed()
        completionHandler(nil)
    }
}
