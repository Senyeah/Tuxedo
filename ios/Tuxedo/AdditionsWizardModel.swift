import Foundation

/// The steps of the Tuxedo Additions wizard (docs/guest-additions-design.md, section 8).
enum AdditionsStep: String, CaseIterable, Identifiable {
    case connect, overview, account, additions, desktop, applications, ssh, review, progress, done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connect: return "Connect"
        case .overview: return "Overview"
        case .account: return "Account"
        case .additions: return "Tuxedo Additions"
        case .desktop: return "Desktop"
        case .applications: return "Applications"
        case .ssh: return "SSH"
        case .review: return "Review"
        case .progress: return "Progress"
        case .done: return "Done"
        }
    }
}

enum AdditionsAccountMode: Equatable {
    /// The job does not touch the account.
    case unchanged
    /// The account the guest has: the job can set its password and the console login.
    case existing
    /// A name the person types: the job makes the account when it is missing.
    case new
}

enum AdditionsAction: Equatable { case none, install, update }

/// The choices of the wizard and the rules on them: what shows, what is on, the job. A value, so the view holds it in
/// @State. The password is a field of it and goes only into the job: print, dump and logs do not show it (see the
/// extension at the end of this file), and wipeSecrets() empties it.
struct AdditionsWizardModel {
    var caps: AdditionsCaps?
    /// The protocol of the agent that reported (nil: it did not say).
    var guestProtocol: Int?
    var versions: AdditionsVersions?
    var catalogue: AdditionsCatalogue?
    var step: AdditionsStep
    /// The account step opens with the question (Set up, Not now) when the app started the wizard by itself.
    var showsIntro: Bool

    var accountMode = AdditionsAccountMode.unchanged
    var userName = AdditionsPolicy.defaultUser
    var password = ""
    var confirm = ""
    var sudo = true
    var autologin = true
    var lockRoot = true
    var hostName = ""
    var installAdditions = false
    var systemUpdate = false
    /// nil: keep the console.
    var desktop: String?
    var apps: Set<String> = []
    var sshEnabled = false
    var sshPortText = "22"
    var sshPasswordLogin = true
    var sshKey = ""

    private(set) var defaultsApplied = false

    init(caps: AdditionsCaps? = nil, guestProtocol: Int? = nil, versions: AdditionsVersions? = nil,
         catalogue: AdditionsCatalogue? = nil, start: AdditionsStep? = nil, intro: Bool = false) {
        self.caps = caps
        self.guestProtocol = guestProtocol
        self.versions = versions
        self.catalogue = catalogue
        step = caps == nil ? .connect : (start ?? .overview)
        showsIntro = intro && caps != nil
        if caps != nil { applyDefaults() }
    }

    // MARK: Caps

    /// A new report: the first one sets the defaults, and every one turns off what the guest cannot do.
    mutating func update(report: AdditionsReport?) {
        guard let report else { return }
        let new = report.caps
        guestProtocol = report.protocolVersion
        caps = new
        if !defaultsApplied { applyDefaults() }
        enforceCaps()
        if step == .connect { step = .overview }
    }

    private mutating func applyDefaults() {
        guard let caps else { return }
        defaultsApplied = true
        let account = caps.account
        let configured = account?.configured == true
        if configured || account == nil {
            accountMode = .unchanged
        } else {
            accountMode = account?.exists == true ? .existing : .new
        }
        if let name = account?.name, account?.exists == true { userName = name }
        sudo = configured ? (account?.sudo ?? true) : true
        autologin = configured ? account?.autologin == "user" : true
        lockRoot = true
        installAdditions = additionsAction != .none
        if let ssh = caps.ssh {
            sshEnabled = ssh.enabled
            sshPortText = String(ssh.port)
            sshPasswordLogin = ssh.passwordAuth
        } else {
            sshPortText = String(catalogue?.ssh.defaultPort ?? 22)
        }
        enforceCaps()
    }

    private mutating func enforceCaps() {
        guard let caps else { return }
        if !caps.network {
            desktop = nil
            apps = []
            systemUpdate = false
        }
        if let d = desktop, caps.desktop == d { desktop = nil }
        apps = apps.filter { caps.apps[$0] != true }
    }

    var network: Bool { caps?.network ?? false }

    /// Why the wizard cannot go on: a legacy guest, or an agent with another protocol.
    var blocker: String? {
        guard let caps else { return nil }
        if caps.legacy { return AdditionsText.legacyGuest }
        if !AdditionsPolicy.protocolSupported(AdditionsReport(protocolVersion: guestProtocol)) { return AdditionsText.protocolOld }
        return nil
    }

    // MARK: Which steps show

    /// What Tuxedo Additions would do in the guest: install what is missing, or update what is older.
    var additionsAction: AdditionsAction {
        guard let caps, let versions, !versions.packages.isEmpty else { return .none }
        if !AdditionsPolicy.outdated(installed: caps.installed, bundled: versions.packages).isEmpty { return .update }
        if !AdditionsPolicy.missing(installed: caps.installed, bundled: versions.packages, optional: versions.optional).isEmpty { return .install }
        return .none
    }

    /// The packages the Tuxedo Additions step would change: not the ones that are current.
    var additionsChanges: [AdditionsPolicy.Change] {
        guard let caps, let versions else { return [] }
        return AdditionsPolicy.changes(installed: caps.installed, bundled: versions.packages, optional: versions.optional)
    }

    var showsAdditionsStep: Bool { additionsAction != .none }
    var showsDesktopStep: Bool { (caps?.desktop ?? "none") == "none" && !(catalogue?.desktops.isEmpty ?? true) }
    var showsApplicationsStep: Bool { !(catalogue?.apps.isEmpty ?? true) }

    /// The steps before the job runs, in order. Connect shows only until there is a report; Tuxedo Additions only when
    /// the guest has less than the app's set; Desktop only when the guest has no desktop and the media offers one.
    var flow: [AdditionsStep] {
        var list: [AdditionsStep] = []
        if caps == nil { list.append(.connect) }
        list += [.overview, .account]
        if showsAdditionsStep { list.append(.additions) }
        if showsDesktopStep { list.append(.desktop) }
        if showsApplicationsStep { list.append(.applications) }
        list += [.ssh, .review]
        return list
    }

    var next: AdditionsStep? {
        guard let i = flow.firstIndex(of: step), i + 1 < flow.count else { return nil }
        return flow[i + 1]
    }

    var back: AdditionsStep? {
        guard let i = flow.firstIndex(of: step), i > 0, !(step == .account && showsIntro) else { return nil }
        return flow[i - 1]
    }

    var canGoNext: Bool { next != nil && blocker == nil && problems(for: step).isEmpty }

    mutating func goNext() {
        if step == .account { showsIntro = false }
        if canGoNext, let next { step = next }
    }

    mutating func goBack() { if let back { step = back } }

    /// The person chose Set up on the introduction.
    mutating func acceptIntro() { showsIntro = false }

    /// The job is set. The password leaves the model: the job holds it now.
    mutating func jobStarted() {
        wipeSecrets()
        step = .progress
    }

    mutating func jobFinished() {
        wipeSecrets()
        step = .done
    }

    /// Swift cannot overwrite a String's bytes; the model drops its copies at once (the job's byte array is wiped apart).
    mutating func wipeSecrets() {
        password = ""
        confirm = ""
    }

    // MARK: Account

    var existingName: String? {
        guard let a = caps?.account, a.exists, let name = a.name, !name.isEmpty else { return nil }
        return name
    }

    var accountModes: [AdditionsAccountMode] {
        (existingName == nil ? [] : [.existing]) + [.new, .unchanged]
    }

    var accountName: String? {
        switch accountMode {
        case .unchanged: return nil
        case .existing: return existingName
        case .new: return userName
        }
    }

    /// The account has a password once the job ran: a new one in the form, or the one the guest reports.
    var accountWillHavePassword: Bool {
        if accountMode != .unchanged && !password.isEmpty { return true }
        if accountMode == .new { return false }
        return caps?.account?.passwordSet == true
    }

    // MARK: Desktop and applications

    struct Choice: Equatable, Identifiable {
        var id: String
        var title: String
        var sizeMB: Int
        var selected: Bool
        /// nil: the person can pick it. Else why not.
        var disabledReason: String?
        /// Short marks on the tile: "Installed", "Needs network".
        var marks: [String]
    }

    static let keepConsoleID = "console"

    var desktopChoices: [Choice] {
        var list = [Choice(id: Self.keepConsoleID, title: "Keep console", sizeMB: 0, selected: desktop == nil, disabledReason: nil, marks: [])]
        for d in catalogue?.desktops ?? [] {
            let installed = caps?.desktop == d.id
            list.append(Choice(id: d.id, title: d.title, sizeMB: d.sizeMB, selected: desktop == d.id,
                               disabledReason: installed ? AdditionsText.installed : (network ? nil : AdditionsText.noNetwork),
                               marks: installed ? [AdditionsText.installed] : (network ? [] : [AdditionsText.needsNetwork])))
        }
        return list
    }

    mutating func chooseDesktop(_ id: String) {
        if id == Self.keepConsoleID { desktop = nil; return }
        guard let choice = desktopChoices.first(where: { $0.id == id }), choice.disabledReason == nil else { return }
        desktop = id
    }

    func appChoices(group: String) -> [Choice] {
        (catalogue?.apps ?? []).filter { $0.group == group }.map { a in
            let installed = caps?.apps[a.id] == true
            return Choice(id: a.id, title: a.title, sizeMB: a.sizeMB, selected: apps.contains(a.id),
                          disabledReason: installed ? AdditionsText.installed : (network ? nil : AdditionsText.noNetwork),
                          marks: installed ? [AdditionsText.installed] : (network ? [] : [AdditionsText.needsNetwork]))
        }
    }

    mutating func toggleApp(_ id: String) {
        guard let a = catalogue?.app(id), caps?.apps[id] != true, network else { return }
        if apps.contains(a.id) { apps.remove(a.id) } else { apps.insert(a.id) }
    }

    /// The applications in the catalogue's order.
    var chosenApps: [AdditionsCatalogue.App] { (catalogue?.apps ?? []).filter { apps.contains($0.id) } }

    // MARK: SSH

    var sshPort: Int? {
        guard let p = AdditionsPolicy.port(sshPortText) else { return nil }
        let limits = catalogue?.ssh ?? AdditionsCatalogue.SSHLimits()
        return AdditionsPolicy.validPort(p, range: limits.portMin...max(limits.portMin, limits.portMax)) ? p : nil
    }

    /// The plus and minus buttons: one step, kept inside the catalogue's range. A text that is not a port starts at the
    /// default port.
    mutating func stepPort(_ delta: Int) {
        let limits = catalogue?.ssh ?? AdditionsCatalogue.SSHLimits()
        let low = limits.portMin, high = max(low, limits.portMax)
        let now = AdditionsPolicy.port(sshPortText) ?? limits.defaultPort
        sshPortText = String(min(max(now + delta, low), high))
    }

    var sshKeyTrimmed: String { AdditionsPolicy.trimmedKey(sshKey) }

    // MARK: Checks

    func problems(for step: AdditionsStep) -> [String] {
        var out: [String] = []
        switch step {
        case .account:
            if accountMode == .new && !AdditionsPolicy.validUserName(userName) { out.append(AdditionsText.userNameRule) }
            if accountMode != .unchanged {
                if let p = AdditionsPolicy.passwordProblem(password, confirm: confirm) { out.append(p) }
                if !sudo && lockRoot { out.append("No one could use root. Allow sudo, or leave root sign-in on.") }
            }
            if !hostName.isEmpty && !AdditionsPolicy.validHostName(hostName) { out.append(AdditionsText.hostNameRule) }
        case .ssh:
            guard sshEnabled else { break }
            if sshPort == nil { out.append(AdditionsText.portRule) }
            if !sshKeyTrimmed.isEmpty && !AdditionsPolicy.validAuthorizedKey(sshKeyTrimmed) { out.append(AdditionsText.keyRule) }
            if sshKeyTrimmed.isEmpty && (!sshPasswordLogin || !accountWillHavePassword) {
                out.append("SSH needs a key or a password. Add a key, or set a password and allow password login.")
            }
        case .review:
            for s in [AdditionsStep.account, .ssh] { out += problems(for: s) }
            if jobSteps().isEmpty { out.append("There is nothing to do. Go back and choose something.") }
        default:
            break
        }
        return out
    }

    // MARK: The job

    /// The steps the choices make, in the order the agent runs them.
    func jobSteps() -> [AdditionsJob.Step] {
        var steps: [AdditionsJob.Step] = []
        if installAdditions && additionsAction != .none { steps.append(.additionsInstall) }
        if let name = accountName {
            steps.append(.userSetup(name: name, password: password.isEmpty ? nil : password, sudo: sudo, autologin: autologin,
                                    lockRoot: lockRoot))
        }
        if !hostName.isEmpty && hostName != caps?.hostname { steps.append(.hostnameSet(name: hostName)) }
        if let d = desktop, network { steps.append(.desktopInstall(id: d)) }
        let ids = chosenApps.map(\.id)
        if !ids.isEmpty && network { steps.append(.appsInstall(ids: ids)) }
        if sshEnabled || caps?.ssh?.enabled == true {
            steps.append(.sshConfigure(enabled: sshEnabled, port: sshPort ?? 22, passwordAuth: sshPasswordLogin, rootLogin: false,
                                       authorizedKey: sshEnabled && !sshKeyTrimmed.isEmpty ? sshKeyTrimmed : nil))
        }
        if systemUpdate && network { steps.append(.systemUpdate) }
        return steps
    }

    /// nil while a step has a problem or there is nothing to do.
    func job(id: String = AdditionsJob.newID()) -> AdditionsJob? {
        guard blocker == nil, problems(for: .review).isEmpty else { return nil }
        return AdditionsJob(id: id, steps: jobSteps())
    }

    // MARK: Review

    struct ReviewLine: Equatable {
        var title: String
        var detail: String
    }

    /// What the job does, in words. It never holds the password.
    var reviewLines: [ReviewLine] {
        jobSteps().map { s in
            switch s {
            case .additionsInstall:
                return ReviewLine(title: s.title(catalogue), detail: additionsAction == .update ? "Update the guest's tools to the app's version." : "Add the guest's tools the app carries.")
            case let .userSetup(name, password, sudo, autologin, lockRoot):
                var parts = [password == nil ? "no new password" : "new password"]
                parts.append(sudo ? "sudo on" : "sudo off")
                parts.append(autologin ? "signs in automatically" : "sign-in prompt")
                if lockRoot { parts.append("root sign-in ends") }
                return ReviewLine(title: "Account \(name)", detail: parts.joined(separator: ", "))
            case .hostnameSet(let name):
                return ReviewLine(title: s.title(catalogue), detail: name)
            case .desktopInstall(let id):
                let d = catalogue?.desktop(id)
                return ReviewLine(title: s.title(catalogue), detail: d.map { "About \(AdditionsCatalogue.sizeText($0.sizeMB)) to download." } ?? "")
            case .appsInstall(let ids):
                // The title names one or two applications: the detail then gives the size, not the same names again.
                guard ids.count > 2 else {
                    let mb = ids.reduce(0) { $0 + (catalogue?.app($1)?.sizeMB ?? 0) }
                    return ReviewLine(title: s.title(catalogue), detail: mb > 0 ? "About \(AdditionsCatalogue.sizeText(mb)) to download." : "")
                }
                return ReviewLine(title: s.title(catalogue), detail: ids.map { catalogue?.app($0)?.title ?? $0 }.joined(separator: ", "))
            case let .sshConfigure(enabled, port, passwordAuth, _, key):
                guard enabled else { return ReviewLine(title: s.title(catalogue), detail: "SSH stops.") }
                var parts = ["port \(port)", passwordAuth ? "password login on" : "password login off", "root login off"]
                if key != nil { parts.append("one key added") }
                return ReviewLine(title: s.title(catalogue), detail: parts.joined(separator: ", "))
            case .systemUpdate:
                return ReviewLine(title: s.title(catalogue), detail: "Install the updates Debian has. The size is not known.")
            }
        }
    }

    /// The download the catalogue names: the desktop and the applications.
    var estimateMB: Int {
        guard network else { return 0 }
        let d = desktop.flatMap { catalogue?.desktop($0)?.sizeMB } ?? 0
        return d + chosenApps.reduce(0) { $0 + $1.sizeMB }
    }

    var estimateText: String? {
        guard estimateMB > 0 else { return nil }
        return "About \(AdditionsCatalogue.sizeText(estimateMB)) to download" + (systemUpdate ? ", and the system updates." : ".")
    }

    /// What the person should know before they start. These do not stop the job.
    var warnings: [String] {
        var out: [String] = []
        if accountMode != .unchanged && !autologin && !accountWillHavePassword { out.append(AdditionsText.noPasswordWarning) }
        if let free = caps?.diskFreeMB, estimateMB > 0, estimateMB > free {
            out.append("The machine has \(AdditionsCatalogue.sizeText(free)) free. This needs more.")
        }
        if let name = accountName, name != AdditionsPolicy.defaultUser { out.append(AdditionsText.tuxMountNote) }
        return out
    }

    // MARK: Overview

    struct Row: Equatable {
        var label: String
        var value: String
    }

    /// What the guest has, for the Overview step.
    var overviewRows: [Row] {
        guard let caps else { return [] }
        var rows: [Row] = []
        if !caps.hostname.isEmpty { rows.append(Row(label: "Machine name", value: caps.hostname)) }
        rows.append(Row(label: "Image", value: caps.image == "desktop" ? "Desktop" : "Console"))
        if caps.desktop != "none" { rows.append(Row(label: "Desktop", value: catalogue?.desktop(caps.desktop)?.title ?? caps.desktop)) }
        rows.append(Row(label: "Network", value: caps.network ? "On" : "Off"))
        if let free = caps.diskFreeMB { rows.append(Row(label: "Free disk", value: AdditionsCatalogue.sizeText(free))) }
        let guest = AdditionsPolicy.guestVersion(caps)
        let app = versions?.packages["tux-guest"]
        rows.append(Row(label: "Tuxedo Additions", value: [guest.map { "guest \($0)" }, app.map { "app \($0)" }].compactMap { $0 }.joined(separator: ", ")))
        if let a = caps.account {
            let name = a.name ?? AdditionsPolicy.defaultUser
            rows.append(Row(label: "Account", value: a.exists ? "\(name), \(a.passwordSet ? "has a password" : "no password")" : "none"))
            rows.append(Row(label: "Console", value: a.autologin == "root" ? "Root shell" : a.autologin == "user" ? "Signs in as the account" : "Sign-in prompt"))
        }
        if let ssh = caps.ssh { rows.append(Row(label: "SSH", value: !ssh.installed ? "Not installed" : ssh.enabled ? "On, port \(ssh.port)" : "Off")) }
        if !caps.ips.isEmpty { rows.append(Row(label: "Addresses", value: caps.ips.joined(separator: ", "))) }
        return rows
    }
}

/// The model holds the new password. Print, dump, String(reflecting:) and the debugger show whether a password is set,
/// never its text.
extension AdditionsWizardModel: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "AdditionsWizardModel(step: \(step.rawValue), account: \(accountName ?? "unchanged"), password: \(password.isEmpty ? "none" : "hidden"))"
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: ["step": step.rawValue, "accountMode": accountMode, "userName": userName,
                                "passwordSet": !password.isEmpty, "sudo": sudo, "autologin": autologin, "lockRoot": lockRoot,
                                "desktop": desktop ?? "none", "apps": apps.sorted(), "sshEnabled": sshEnabled])
    }
}

/// How the wizard's tiles fit the screen it is on: a phone, an iPad, a monitor.
enum AdditionsLayout {
    /// The smallest width of a tile for GridItem(.adaptive(minimum:)): two columns on a phone, three on a tablet,
    /// four on a big screen, and wider tiles for larger text. width is the container's.
    static func tileMinimum(width: CGFloat, textScale: CGFloat = 1) -> CGFloat {
        let usable = max(width - 2 * margin, 0)
        let columns: CGFloat = usable < 520 ? 2 : usable < 820 ? 3 : 4
        let fit = (usable - (columns - 1) * gap) / columns - 1 // a point of room, so rounding keeps the count
        let wanted = min(max(fit, 140), 260) * min(max(textScale, 1), 1.6)
        return min(wanted, max(usable, 140))
    }

    static let margin: CGFloat = 16
    static let gap: CGFloat = 12
    static let touchTarget: CGFloat = 44
    static let primaryTarget: CGFloat = 56
    /// The widest the text of a page runs.
    static let maxContent: CGFloat = 960
}
