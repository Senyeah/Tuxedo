import SwiftUI
import UIKit

/// A Linux machine's folders from Files, in its settings: each at /media/henge/<name> in the guest.
struct FoldersSection: View {
    let machine: UUID
    @ObservedObject private var machines = Machines.shared
    @ObservedObject private var session = FolderSession.shared
    @State private var picking = false
    @State private var error: String?

    private var folders: [SharedFolder] { machines.all.first { $0.id == machine }?.folders ?? [] }
    private var running: Bool { session.machine == machine }

    var body: some View {
        DeskHeading("Folders")
        VStack(spacing: 0) {
            ForEach(folders) { folder in
                NavigationLink { FolderDetailView(machine: machine, id: folder.id) } label: { row(folder) }
                Rectangle().fill(Desk.hairline).frame(height: 0.5)
            }
            Button { picking = true } label: {
                HStack {
                    Text("Add Folder").font(.system(size: 16))
                    Spacer()
                    Image(systemName: "folder.badge.plus")
                }
                .foregroundStyle(folders.count < FolderPolicy.maxFolders ? Desk.accentLight : Desk.faint)
                .padding(.horizontal, 17)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .disabled(folders.count >= FolderPolicy.maxFolders)
        }
        .deskCard()
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { add($0) }
        VStack(alignment: .leading, spacing: 6) {
            if let error { Text(error).foregroundStyle(Desk.bad) }
            if let note = FolderPolicy.addNote(count: folders.count, running: running, device: session.device) { Text(note) }
            Text("Linux sees each folder at /media/henge/<name>. Changes apply at once while the machine runs.")
        }
        .font(.system(size: 13)).foregroundStyle(Desk.dim)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 17)
        .padding(.top, 8)
    }

    private func row(_ folder: SharedFolder) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder").foregroundStyle(Desk.accentLight)
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name).font(.system(size: 16)).foregroundStyle(Desk.text)
                Text([folder.displayPath, FolderPolicy.title(folder.mode)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(Desk.dim).lineLimit(1)
            }
            Spacer()
            if let state = FolderPolicy.shownState(running: running ? session.states[folder.id] : nil, lost: folder.lost) {
                FolderStateLabel(state: state)
            }
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.faint)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func add(_ result: Result<URL, Error>) {
        error = nil
        switch result {
        case .failure(let e): error = e.localizedDescription
        case .success(let url):
            guard let made = FolderPick.bookmark(url) else {
                error = "Tuxedo cannot keep access to that folder."
                return
            }
            var added: SharedFolder?
            machines.updateFolders(of: machine) { list in
                guard list.count < FolderPolicy.maxFolders else { return }
                let f = SharedFolder(name: FolderPolicy.safeName(url.lastPathComponent, taken: list.map(\.name)),
                                     bookmark: made, displayPath: FolderPick.place(url))
                list.append(f)
                added = f
            }
            if let added { TuxLog.log("folders", "added \(added.name) (\(FolderPolicy.title(added.mode)))") }
            FolderPick.applyIfRunning(machine)
        }
    }
}

/// The folders on a page of their own: the running session's Details has them, as settings is behind the session.
struct FoldersPage: View {
    let machine: UUID
    var body: some View {
        ScrollView {
            VStack(spacing: 0) { FoldersSection(machine: machine) }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .deskColumn()
        }
        .background(Desk.page)
        .navigationTitle("Folders")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A folder from the picker, as a bookmark.
enum FolderPick {
    static func bookmark(_ url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func place(_ url: URL) -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return FolderPolicy.displayPath(url.path, appDocuments: docs.resolvingSymlinksInPath().path)
    }

    @MainActor static func applyIfRunning(_ machine: UUID) {
        if let machine = Machines.shared.all.first(where: { $0.id == machine }) { FolderSession.shared.changed(machine) }
    }
}

struct FolderStateLabel: View {
    let state: FolderPolicy.State
    var body: some View {
        Text(FolderPolicy.label(state))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(state == .ready ? Desk.good : state == .unavailable ? Desk.warn : Desk.bad)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Desk.raised, in: Capsule())
    }
}

/// One folder: its name, mode, Pick Again, the changes of a Copy-on-write folder, and Remove.
struct FolderDetailView: View {
    let machine: UUID
    let id: UUID
    @ObservedObject private var machines = Machines.shared
    @ObservedObject private var session = FolderSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var picking = false
    @State private var pendingMode: SharedFolder.Mode?
    @State private var confirmDiscard = false
    @State private var confirmRemove = false
    @State private var error: String?

    private var folder: SharedFolder? { machines.all.first { $0.id == machine }?.folders?.first { $0.id == id } }
    private var running: Bool { session.machine == machine }

    var body: some View {
        ScrollView {
            if let folder {
                VStack(spacing: 0) {
                    DeskHeading("Name in Linux")
                    TextField("Name", text: $name)
                        .font(.system(size: 16))
                        .submitLabel(.done)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 14)
                        .deskCard()
                        .onSubmit(rename)
                    note("/media/henge/\(name.isEmpty ? folder.name : name)")

                    DeskHeading("Where")
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(folder.displayPath ?? "A folder in Files").font(.system(size: 16))
                            Spacer()
                            if let state = FolderPolicy.shownState(running: running ? session.states[id] : nil, lost: folder.lost) {
                                FolderStateLabel(state: state)
                            }
                        }
                        Button("Pick Again…") { picking = true }
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
                    }
                    .padding(17)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .deskCard()
                    note("Pick the folder again after it moved, after a reinstall of Tuxedo, or to use another. Copy-on-write changes stay on top of the new one.")

                    DeskHeading("Mode")
                    modes(folder)
                    note("A new mode applies once nothing in Linux has the folder open.")

                    if folder.mode == .copyOnWrite { changes(folder) }

                    DeskHeading("Manage")
                    Button { confirmRemove = true } label: {
                        HStack {
                            Text("Remove Folder").font(.system(size: 16)).foregroundStyle(Desk.bad)
                            Spacer()
                        }
                        .padding(.horizontal, 17)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .deskCard()
                    if let error { note(error, color: Desk.bad) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .deskColumn()
                .confirmationDialog("Change the mode of \(folder.name)?", isPresented: Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } }), titleVisibility: .visible) {
                    Button("Change to \(FolderPolicy.title(pendingMode ?? .readWrite))") {
                        if let m = pendingMode { setMode(m) }
                        pendingMode = nil
                    }
                } message: {
                    Text(FolderPolicy.modeChangeWarning(from: folder.mode, to: pendingMode ?? folder.mode) ?? "")
                }
                .confirmationDialog("Discard the changes to \(folder.name)?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                    Button("Discard Changes", role: .destructive) { session.discard(id) }
                } message: {
                    Text(FolderPolicy.discardMessage)
                }
                .confirmationDialog("Remove \(folder.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                    Button("Remove", role: .destructive, action: remove)
                } message: {
                    Text(FolderPolicy.removeMessage(folder))
                }
            }
        }
        .background(Desk.page)
        .navigationTitle(folder?.name ?? "Folder")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = folder?.name ?? "" }
        .onDisappear(perform: rename)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { pickAgain($0) }
    }

    private func note(_ text: String, color: Color = Desk.dim) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 17)
            .padding(.top, 8)
    }

    private func modes(_ folder: SharedFolder) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(SharedFolder.Mode.allCases.enumerated()), id: \.offset) { i, mode in
                if i > 0 { Rectangle().fill(Desk.hairline).frame(height: 0.5) }
                Button {
                    guard mode != folder.mode else { return }
                    if FolderPolicy.modeChangeWarning(from: folder.mode, to: mode) != nil { pendingMode = mode } else { setMode(mode) }
                } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(FolderPolicy.title(mode)).font(.system(size: 16)).foregroundStyle(Desk.text)
                            Text(FolderPolicy.detail(mode)).font(.system(size: 13)).foregroundStyle(Desk.dim)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        if folder.mode == mode { Image(systemName: "checkmark").foregroundStyle(Desk.accentLight) }
                    }
                    .padding(.horizontal, 17)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(folder.mode == mode ? .isSelected : [])
            }
        }
        .deskCard()
    }

    @ViewBuilder private func changes(_ folder: SharedFolder) -> some View {
        DeskHeading("Changes in Linux")
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                Button("Export Changes") { session.clearAsk(id); session.export(id) }
                    .disabled(!session.canAsk(folder, machine: machine))
                Button("Discard Changes…", role: .destructive) { confirmDiscard = true }
                    .disabled(!session.canAsk(folder, machine: machine))
            }
            .font(.system(size: 15, weight: .semibold))
            switch session.asks[id] {
            case .exporting?: ProgressView("Exporting…").font(.system(size: 13))
            case .discarding?: ProgressView("Discarding…").font(.system(size: 13))
            case .exported(let url, let summary)?:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Exported to Files, under Tuxedo, Shared, Exports, \(url.lastPathComponent)\(summary.isEmpty ? "" : ": \(summary)"). Files opens in front of Tuxedo, and the machine can pause until you come back.")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    Button("Show in Files") {
                        if let files = FolderPolicy.filesURL(url) { UIApplication.shared.open(files) }
                    }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
                }
            case .discarded?: Text("The changes were discarded.").font(.system(size: 13)).foregroundStyle(Desk.dim)
            case .failed(let why)?: Text(why).font(.system(size: 13)).foregroundStyle(Desk.bad)
            case nil: EmptyView()
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deskCard()
        note(running && session.device
             ? "Export copies the files Linux changed to Files, with a list of what it deleted. The folder in Files does not change."
             : "Start this machine to export or discard the changes Linux made. They are on the machine's disk.")
    }

    private func save(_ change: (inout SharedFolder) -> Void) {
        machines.updateFolders(of: machine) { list in
            if let i = list.firstIndex(where: { $0.id == id }) { change(&list[i]) }
        }
        FolderPick.applyIfRunning(machine)
    }

    private func rename() {
        guard let folder else { return }
        let others = (machines.all.first { $0.id == machine }?.folders ?? []).filter { $0.id != id }.map(\.name)
        let safe = FolderPolicy.safeName(name.isEmpty ? folder.name : name, taken: others)
        name = safe
        guard safe != folder.name else { return }
        save { $0.name = safe }
    }

    private func setMode(_ mode: SharedFolder.Mode) {
        save { $0.mode = mode }
        session.clearAsk(id)
    }

    private func pickAgain(_ result: Result<URL, Error>) {
        error = nil
        switch result {
        case .failure(let e): error = e.localizedDescription
        case .success(let url):
            guard let made = FolderPick.bookmark(url) else {
                error = "Tuxedo cannot keep access to that folder."
                return
            }
            save {
                $0.bookmark = made
                $0.displayPath = FolderPick.place(url)
                $0.lost = nil
            }
        }
    }

    private func remove() {
        machines.updateFolders(of: machine) { $0.removeAll { $0.id == id } }
        FolderPick.applyIfRunning(machine)
        dismiss()
    }
}
