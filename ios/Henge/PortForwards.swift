import Network
import SwiftUI
import UIKit

/// The running Linux machine's port forwards (ForwardPolicy, host/net_forward.h). The session starts this before the
/// machine boots and ends it when the machine stops. The engine listens; this follows the phone's network and reads
/// back where each rule listens.
@MainActor
final class ForwardSession: ObservableObject {
    static let shared = ForwardSession()

    /// The machine whose forwards are up, or nil.
    @Published private(set) var machine: UUID?
    /// By rule id, for the rules the engine has.
    @Published private(set) var states: [UUID: ForwardPolicy.Shown] = [:]

    private var active: [PortForward] = []
    private var monitor: NWPathMonitor?
    private var poll: Task<Void, Never>?

    func start(_ machine: VirtualMachine) {
        end()
        self.machine = machine.id
        apply(machine.forwards ?? [])
        let m = NWPathMonitor()
        m.pathUpdateHandler = { _ in
            tux_vm_forwards_refresh() // the engine's own poll would see it within 5 s
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                ForwardSession.shared.read()
            }
        }
        m.start(queue: DispatchQueue(label: "tux.forwards"))
        monitor = m
        poll = Task { [weak self] in
            while !Task.isCancelled {
                self?.read()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func end() {
        monitor?.cancel()
        monitor = nil
        poll?.cancel()
        poll = nil
        tux_vm_forwards_set(nil, nil, 0)
        active = []
        states = [:]
        machine = nil
    }

    /// Settings changed this machine's forwards while it runs: they apply at once.
    func changed(_ machine: VirtualMachine) {
        guard self.machine == machine.id else { return }
        apply(machine.forwards ?? [])
        read()
    }

    private func apply(_ list: [PortForward]) {
        active = ForwardPolicy.active(list)
        let phone = active.map { UInt16($0.phonePort) }, guest = active.map { UInt16($0.guestPort) }
        if tux_vm_forwards_set(phone, guest, Int32(active.count)) != 0 {
            TuxLog.log("forwards", "the engine refused \(active.count) forwards")
            active = []
        } else if !active.isEmpty {
            TuxLog.log("forwards", active.map { "\($0.phonePort) -> \($0.guestPort)" }.joined(separator: ", "))
        }
    }

    func read() {
        guard machine != nil else { return }
        var next: [UUID: ForwardPolicy.Shown] = [:]
        var buf = [CChar](repeating: 0, count: 1024)
        for f in active {
            var err: Int32 = 0
            let n = tux_vm_forward_state(UInt16(f.phonePort), &buf, buf.count, &err)
            next[f.id] = ForwardPolicy.shown(count: n, err: err, text: String(cString: buf), phonePort: f.phonePort, device: Device.name)
        }
        if next != states { states = next }
    }
}

enum ForwardEdit {
    @MainActor static func change(_ machine: UUID, _ edit: (inout [PortForward]) -> Void) {
        Machines.shared.updateForwards(of: machine, edit)
        if let machine = Machines.shared.all.first(where: { $0.id == machine }) { ForwardSession.shared.changed(machine) }
    }
}

/// A Linux machine's forwards in its settings.
struct ForwardsSection: View {
    let machine: UUID
    @ObservedObject private var machines = Machines.shared
    @ObservedObject private var session = ForwardSession.shared

    private var forwards: [PortForward] { machines.all.first { $0.id == machine }?.forwards ?? [] }

    var body: some View {
        DeskHeading("Port forwards")
        VStack(spacing: 0) {
            ForEach(Array(forwards.enumerated()), id: \.element.id) { i, f in
                NavigationLink { ForwardDetailView(machine: machine, id: f.id) } label: { row(f, problem: ForwardPolicy.problem(forwards, at: i)) }
                Rectangle().fill(Desk.hairline).frame(height: 0.5)
            }
            if ForwardPolicy.canAddSSH(forwards) {
                addButton("Add SSH (2222 → 22)", symbol: "terminal") {
                    ForwardEdit.change(machine) { $0.append(ForwardPolicy.sshPreset()) }
                }
                Rectangle().fill(Desk.hairline).frame(height: 0.5)
            }
            addButton("Add Forward", symbol: "plus") {
                ForwardEdit.change(machine) { list in
                    if list.count < ForwardPolicy.maxRules { list.append(ForwardPolicy.newRule(list)) }
                }
            }
            .disabled(forwards.count >= ForwardPolicy.maxRules)
        }
        .deskCard()
        Text("Another device on the same Wi-Fi, Ethernet or VPN (Tailscale too) connects to this \(Device.name) at the phone port, and reaches the guest's port. Never over cellular. While Henge is in the background a paused machine answers when you come back. Changes apply at once.")
            .font(.system(size: 13)).foregroundStyle(Desk.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 17)
            .padding(.top, 8)
    }

    private func addButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 16))
                Spacer()
                Image(systemName: symbol)
            }
            .foregroundStyle(forwards.count < ForwardPolicy.maxRules ? Desk.accentLight : Desk.faint)
            .padding(.horizontal, 17)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
    }

    private func row(_ f: PortForward, problem: ForwardPolicy.Problem?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.left.arrow.right").foregroundStyle(f.enabled ? Desk.accentLight : Desk.faint)
            VStack(alignment: .leading, spacing: 3) {
                Text(ForwardPolicy.title(f)).font(.system(size: 16)).foregroundStyle(Desk.text)
                Text("Phone \(String(f.phonePort)) → guest \(String(f.guestPort))")
                    .font(.system(size: 13)).foregroundStyle(Desk.dim)
            }
            Spacer()
            ForwardStateLabel(enabled: f.enabled, problem: problem, shown: session.machine == machine ? session.states[f.id] : nil)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.faint)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

struct ForwardStateLabel: View {
    let enabled: Bool
    let problem: ForwardPolicy.Problem?
    let shown: ForwardPolicy.Shown?

    var body: some View {
        if let label {
            Text(label.0)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(label.1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Desk.raised, in: Capsule())
        }
    }

    private var label: (String, Color)? {
        if problem != nil { return ("Fix", Desk.bad) }
        if !enabled { return ("Off", Desk.faint) }
        switch shown {
        case .listening?: return ("Open", Desk.good)
        case .noLocalNetwork?: return ("No network", Desk.warn)
        case .failed?: return ("In use", Desk.bad)
        case .off?, nil: return nil
        }
    }
}

/// One forward: its name, ports, on or off, and Remove.
struct ForwardDetailView: View {
    let machine: UUID
    let id: UUID
    @ObservedObject private var machines = Machines.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var phone = ""
    @State private var guest = ""
    @State private var pending: Task<Void, Never>?

    private var list: [PortForward] { machines.all.first { $0.id == machine }?.forwards ?? [] }
    private var index: Int? { list.firstIndex { $0.id == id } }

    var body: some View {
        ScrollView {
            if let i = index {
                let f = list[i]
                VStack(spacing: 0) {
                    DeskHeading("Name")
                    field("Name", text: $name, numeric: false)
                    DeskHeading("Ports")
                    VStack(spacing: 0) {
                        labelled("Phone port", field("2222", text: $phone, numeric: true, card: false))
                        Rectangle().fill(Desk.hairline).frame(height: 0.5)
                        labelled("Guest port", field("22", text: $guest, numeric: true, card: false))
                    }
                    .deskCard()
                    if let blank = blankNote(f) {
                        note(blank, color: Desk.bad)
                    } else if let p = ForwardPolicy.problem(draft(list), at: i) {
                        note(ForwardPolicy.problemText(p), color: Desk.bad)
                    } else {
                        note("Other devices connect to this \(Device.name)'s port \(String(f.phonePort)); the guest gets it on port \(String(f.guestPort)).")
                    }
                    Toggle("On", isOn: Binding(get: { f.enabled }, set: { on in edit { $0.enabled = on } }))
                        .font(.system(size: 16))
                        .padding(.horizontal, 17)
                        .padding(.vertical, 10)
                        .deskCard()
                        .padding(.top, 18)
                    DeskHeading("Manage")
                    Button {
                        ForwardEdit.change(machine) { $0.removeAll { $0.id == id } }
                        dismiss()
                    } label: {
                        HStack {
                            Text("Remove Forward").font(.system(size: 16)).foregroundStyle(Desk.bad)
                            Spacer()
                        }
                        .padding(.horizontal, 17)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .deskCard()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .deskColumn()
            }
        }
        .background(Desk.page)
        .navigationTitle(index.map { ForwardPolicy.title(list[$0]) } ?? "Forward")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard let i = index else { return }
            name = list[i].name ?? ""
            phone = String(list[i].phonePort)
            guest = String(list[i].guestPort)
        }
        .onChange(of: phone) { _ in later() }
        .onChange(of: guest) { _ in later() }
        .onChange(of: name) { _ in later() }
        .onDisappear {
            pending?.cancel()
            commit()
        }
    }

    /// Typing 22222 passes through 2222: save only after a pause, so a half-typed port never binds.
    private func later() {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !Task.isCancelled { commit() }
        }
    }

    /// The fields into the stored rule; a blank or non-numeric port keeps the stored one.
    private func commit() {
        guard let i = index else { return }
        let f = list[i]
        let p = ForwardPolicy.port(phone) ?? f.phonePort, g = ForwardPolicy.port(guest) ?? f.guestPort
        let n = ForwardPolicy.cleanName(name)
        if p != f.phonePort || g != f.guestPort || n != f.name {
            edit {
                $0.phonePort = p
                $0.guestPort = g
                $0.name = n
            }
        }
    }

    /// The list with this rule's typed ports, for the problem note before they are saved.
    private func draft(_ list: [PortForward]) -> [PortForward] {
        list.map { f in
            guard f.id == id else { return f }
            var d = f
            d.phonePort = ForwardPolicy.port(phone) ?? f.phonePort
            d.guestPort = ForwardPolicy.port(guest) ?? f.guestPort
            return d
        }
    }

    private func blankNote(_ f: PortForward) -> String? {
        if ForwardPolicy.port(phone) == nil { return "Enter a phone port. Until then the forward keeps port \(String(f.phonePort))." }
        if ForwardPolicy.port(guest) == nil { return "Enter a guest port. Until then the forward keeps port \(String(f.guestPort))." }
        return nil
    }

    private func edit(_ change: (inout PortForward) -> Void) {
        ForwardEdit.change(machine) { list in
            if let i = list.firstIndex(where: { $0.id == id }) { change(&list[i]) }
        }
    }

    private func labelled(_ title: String, _ content: some View) -> some View {
        HStack {
            Text(title).font(.system(size: 16))
            Spacer()
            content.frame(maxWidth: 120)
        }
        .padding(.leading, 17)
    }

    @ViewBuilder private func field(_ prompt: String, text: Binding<String>, numeric: Bool, card: Bool = true) -> some View {
        let f = TextField(prompt, text: text)
            .font(.system(size: 16))
            .multilineTextAlignment(numeric ? .trailing : .leading)
            .keyboardType(numeric ? .numberPad : .default)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .padding(.horizontal, 17)
            .padding(.vertical, 14)
        if card { f.deskCard() } else { f }
    }

    private func note(_ text: String, color: Color = Desk.dim) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 17)
            .padding(.top, 8)
    }
}

/// The forwards on a page of their own, for the running session's Details.
struct ForwardsPage: View {
    let machine: UUID
    var body: some View {
        ScrollView {
            VStack(spacing: 0) { ForwardsSection(machine: machine) }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .deskColumn()
        }
        .background(Desk.page)
        .navigationTitle("Port Forwards")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Details while the machine runs: where to connect for each forward, with a copy button.
struct ForwardsDetails: View {
    let machine: UUID
    @ObservedObject private var machines = Machines.shared
    @ObservedObject private var session = ForwardSession.shared
    @State private var copied: String?

    private var forwards: [PortForward] { machines.all.first { $0.id == machine }?.forwards ?? [] }

    var body: some View {
        if forwards.isEmpty {
            Text("None. A forward lets another device on your network reach this machine, for example over SSH.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(forwards) { f in
            VStack(alignment: .leading, spacing: 6) {
                Text("\(ForwardPolicy.title(f)) · phone \(String(f.phonePort)) → guest \(String(f.guestPort))").font(.subheadline.weight(.semibold))
                state(f)
            }
            .padding(.vertical, 2)
        }
        NavigationLink { ForwardsPage(machine: machine) } label: {
            LabeledContent("Edit Port Forwards", value: "\(forwards.count)")
        }
    }

    @ViewBuilder private func state(_ f: PortForward) -> some View {
        if !f.enabled {
            Text("Off.").font(.footnote).foregroundStyle(.secondary)
        } else if let p = ForwardPolicy.problem(forwards, at: forwards.firstIndex(of: f) ?? 0) {
            Text(ForwardPolicy.problemText(p)).font(.footnote).foregroundStyle(.red)
        } else {
            switch session.states[f.id] ?? .off {
            case .off:
                Text("Opening…").font(.footnote).foregroundStyle(.secondary)
            case .listening(let local, _):
                ForEach(local, id: \.self) { a in connect(f, a) }
            case .noLocalNetwork(let loopback):
                Text(ForwardPolicy.noLocalNetworkText).font(.footnote).foregroundStyle(.orange)
                if loopback { connect(f, ForwardPolicy.Address(ip: "127.0.0.1", interface: "lo0")) }
            case .failed(let why, let local):
                Text(why).font(.footnote).foregroundStyle(.red)
                ForEach(local, id: \.self) { a in connect(f, a) }
            }
        }
    }

    private func connect(_ f: PortForward, _ a: ForwardPolicy.Address) -> some View {
        let text = ForwardPolicy.connectText(f, address: a.ip)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Text(a.isLoopback ? "Only from an app on this \(Device.name)" : ForwardPolicy.networkName(a.interface))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                UIPasteboard.general.string = text
                copied = text
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == text { copied = nil } }
            } label: {
                Image(systemName: copied == text ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(copied == text ? "Copied" : "Copy \(text)")
        }
    }
}
