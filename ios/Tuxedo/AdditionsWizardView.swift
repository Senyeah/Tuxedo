import SwiftUI
import UIKit

/// The Tuxedo Additions wizard (docs/guest-additions-design.md, section 8): a full-screen sheet that sends choices to
/// the guest's agent. The rules are AdditionsWizardModel's; this file only draws them. Tiles fit the width of the
/// screen it is on, so it works on a phone, an iPad and a monitor, upright and on its side.
struct AdditionsWizardView: View {
    @ObservedObject var additions: TuxAdditions
    let request: AdditionsWizardRequest
    /// Types a line into the guest (the paste path of Sharing.swift).
    let typeCommand: (String) -> Void
    let close: () -> Void

    @State private var model: AdditionsWizardModel
    @State private var waited = false
    @State private var cancelling = false
    @State private var width: CGFloat = 390
    @ScaledMetric(relativeTo: .body) private var textScale = 1.0

    init(additions: TuxAdditions, request: AdditionsWizardRequest, typeCommand: @escaping (String) -> Void, close: @escaping () -> Void) {
        self.additions = additions
        self.request = request
        self.typeCommand = typeCommand
        self.close = close
        var m = AdditionsWizardModel(caps: additions.state.caps, guestProtocol: additions.state.report?.protocolVersion,
                                     versions: additions.versions, catalogue: additions.catalogue, start: request.step, intro: request.intro)
        // A running job, or a finished one whose page the person has not left. A job that ended with no done is dead.
        if let job = additions.state.job {
            if job.done != nil { m.step = .done } else if !job.over { m.step = .progress }
        }
        _model = State(initialValue: m)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView {
                    content
                        .frame(maxWidth: AdditionsLayout.maxContent, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, AdditionsLayout.margin)
                        .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { width = min(geo.size.width, AdditionsLayout.maxContent) }
                .onChange(of: geo.size.width) { _, new in width = min(new, AdditionsLayout.maxContent) }
            }
            .background(Desk.page.ignoresSafeArea())
            .navigationTitle(model.step.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !(model.step == .account && model.showsIntro) {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", action: closeTapped)
                            .accessibilityLabel("Close Tuxedo Additions")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        }
        .onAppear {
            additions.wizardOpened(showingJob: model.step == .progress || model.step == .done)
            additions.insert() // the engine decides: a second call does nothing
        }
        .onDisappear { model.wipeSecrets() }
        .onChange(of: additions.state.report) { _, report in model.update(report: report) }
        .onChange(of: additions.state.job?.over == true) { _, over in // done, cancelled before pickup, refused, no answer
            if over && model.step == .progress { model.jobFinished() }
        }
        .task(id: model.step == .connect) {
            waited = false
            guard model.step == .connect else { return }
            try? await Task.sleep(nanoseconds: UInt64(AdditionsPolicy.connectWait * 1_000_000_000))
            waited = !Task.isCancelled
        }
        .interactiveDismissDisabled()
    }

    private func closeTapped() {
        model.wipeSecrets()
        if model.step == .done { additions.finishJob() }
        close()
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .connect: connect
        case .overview: overview
        case .account: account
        case .additions: additionsStep
        case .desktop: desktop
        case .applications: applications
        case .ssh: ssh
        case .review: review
        case .progress: progress
        case .done: done
        }
    }

    private var tileColumns: [GridItem] {
        [GridItem(.adaptive(minimum: AdditionsLayout.tileMinimum(width: width, textScale: textScale)), spacing: AdditionsLayout.gap, alignment: .top)]
    }

    // MARK: The bar

    private var showsBar: Bool {
        ![.connect, .progress, .done].contains(model.step) && !(model.step == .account && model.showsIntro)
    }

    private var position: String? {
        guard let i = model.flow.firstIndex(of: model.step) else { return nil }
        return "Step \(i + 1) of \(model.flow.count)"
    }

    @ViewBuilder private var bottomBar: some View {
        if showsBar {
            VStack(spacing: 8) {
                if let position { Text(position).font(.footnote).foregroundStyle(Desk.dim) }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { backButton; primaryButton }
                    VStack(spacing: 8) { primaryButton; backButton }
                }
            }
            .padding(.horizontal, AdditionsLayout.margin)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    @ViewBuilder private var backButton: some View {
        if model.back != nil {
            Button { model.goBack() } label: { Text("Back").frame(minWidth: 88) }
                .buttonStyle(WizardSecondaryStyle())
                .accessibilityLabel("Back to the last step")
        }
    }

    @ViewBuilder private var primaryButton: some View {
        if model.step == .review {
            let job = model.job()
            Button(action: startJob) { Text("Start") }
                .buttonStyle(WizardPrimaryStyle(enabled: job != nil && additions.hasMedia))
                .disabled(job == nil || !additions.hasMedia)
                .accessibilityLabel("Start the job")
                .accessibilityHint(job == nil ? "Fix the problems first." : "Sends your choices to the machine.")
        } else {
            Button { model.goNext() } label: { Text("Continue") }
                .buttonStyle(WizardPrimaryStyle(enabled: model.canGoNext))
                .disabled(!model.canGoNext)
                .accessibilityLabel("Continue to \(model.next?.title ?? "the next step")")
        }
    }

    private func startJob() {
        guard let job = model.job() else { return }
        if additions.start(job: job) { model.jobStarted() }
    }

    // MARK: Connect

    private var connect: some View {
        VStack(alignment: .leading, spacing: 16) {
            card {
                HStack(spacing: 12) {
                    ProgressView().accessibilityHidden(true)
                    Text(AdditionsText.connectWaiting).font(.body)
                }
                if let problem = additions.lastError ?? additions.state.badMedia { warn(problem, bad: true) }
                if !additions.hasMedia { warn(AdditionsText.notInThisApp, bad: true) }
            }
            if waited { bootstrap }
        }
    }

    private var bootstrap: some View {
        card {
            Text(AdditionsText.connectBootstrap).font(.body)
            Text(AdditionsPolicy.bootstrapCommand)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Desk.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Command: \(AdditionsPolicy.bootstrapCommand)")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { copyButton; typeButton }
                VStack(spacing: 8) { typeButton; copyButton }
            }
            Button {
                additions.askAgain()
            } label: { Text("Ask the guest again").frame(maxWidth: .infinity) }
                .buttonStyle(WizardSecondaryStyle())
                .accessibilityLabel("Ask the guest for a new report")
        }
    }

    private var copyButton: some View {
        Button { UIPasteboard.general.string = AdditionsPolicy.bootstrapCommand } label: {
            Label(AdditionsText.copyCommands, systemImage: "doc.on.doc").frame(maxWidth: .infinity)
        }
        .buttonStyle(WizardSecondaryStyle())
        .accessibilityLabel("Copy the command")
    }

    private var typeButton: some View {
        Button { typeCommand(AdditionsPolicy.bootstrapCommand) } label: {
            Label(AdditionsText.typeCommands, systemImage: "keyboard").frame(maxWidth: .infinity)
        }
        .buttonStyle(WizardPrimaryStyle())
        .accessibilityLabel("Type the command into the machine's console")
    }

    // MARK: Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let blocker = model.blocker { card { warn(blocker, bad: true) } }
            card {
                ForEach(model.overviewRows, id: \.label) { row in
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.label).foregroundStyle(Desk.dim)
                            Spacer(minLength: 12)
                            Text(row.value).multilineTextAlignment(.trailing)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.label).foregroundStyle(Desk.dim)
                            Text(row.value)
                        }
                    }
                    .frame(minHeight: AdditionsLayout.touchTarget / 1.5)
                    .accessibilityElement(children: .combine)
                }
            }
            if model.additionsAction == .update { card { warn(AdditionsText.updateBanner, bad: false) } }
            note("Choose what to set up on the next steps. Nothing changes until you press Start.")
        }
    }

    // MARK: Account

    private var account: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.showsIntro { intro } else { accountForm }
        }
    }

    @ViewBuilder private var intro: some View {
        card {
            Image(systemName: "person.crop.circle.badge.plus").font(.largeTitle).foregroundStyle(Desk.accentLight).accessibilityHidden(true)
            Text(AdditionsText.promptTitle).font(.title2.weight(.bold))
            Text(AdditionsText.promptBody).font(.body)
            note(AdditionsText.rootShellNote)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { notNowButton; setUpButton }
                VStack(spacing: 8) { setUpButton; notNowButton }
            }
        }
        card {
            Text("What the wizard can do").font(.headline)
            ForEach(AdditionsText.introPoints, id: \.self) { point in
                Label {
                    Text(point).font(.subheadline).foregroundStyle(Desk.dim)
                } icon: {
                    Image(systemName: "checkmark").foregroundStyle(Desk.accentLight)
                }
                .labelStyle(TopIconLabelStyle())
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var setUpButton: some View {
        Button { model.acceptIntro() } label: { Text(AdditionsText.promptSetUp) }
            .buttonStyle(WizardPrimaryStyle())
            .accessibilityLabel("Set up the account now")
    }

    private var notNowButton: some View {
        Button {
            additions.dismissPrompt()
            close()
        } label: { Text(AdditionsText.promptNotNow).frame(minWidth: 120) }
            .buttonStyle(WizardSecondaryStyle())
            .accessibilityLabel("Not now")
            .accessibilityHint("The prompt does not come back for this machine. You can open Tuxedo Additions from Details.")
    }

    @ViewBuilder private var accountForm: some View {
        if model.caps?.account?.autologin == "root" { note(AdditionsText.rootShellNote) }
        LazyVGrid(columns: tileColumns, spacing: AdditionsLayout.gap) {
            ForEach(model.accountModes, id: \.self) { mode in
                ChoiceTile(title: accountModeTitle(mode), detail: accountModeDetail(mode), marks: [], selected: model.accountMode == mode,
                           reason: nil) { model.accountMode = mode }
            }
        }
        if model.accountMode != .unchanged {
            card {
                if model.accountMode == .new {
                    Text("Name").font(.headline)
                    TextField("Account name", text: $model.userName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                        .frame(minHeight: AdditionsLayout.touchTarget)
                        .background(Desk.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityLabel("Account name")
                } else if let name = model.existingName {
                    Text("Account \(name)").font(.headline)
                }
                Text(passwordTitle).font(.headline)
                SecureField("Password", text: $model.password)
                    .textInputAutocapitalization(.never) // no textContentType: iOS must not offer to save the password
                    .autocorrectionDisabled()
                    .padding(12)
                    .frame(minHeight: AdditionsLayout.touchTarget)
                    .background(Desk.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("Password")
                SecureField("Password again", text: $model.confirm)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .frame(minHeight: AdditionsLayout.touchTarget)
                    .background(Desk.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("Confirm the password")
                note("The password goes to the machine once. The app does not keep it.")
            }
            card {
                toggle("Allow sudo", AdditionsText.sudoNote, $model.sudo)
                toggle("Sign in automatically", AdditionsText.autologinNote, $model.autologin)
                toggle("Lock root sign-in", AdditionsText.lockRootNote, $model.lockRoot)
            }
        }
        card {
            Text("Machine name").font(.headline)
            TextField(model.caps?.hostname.isEmpty == false ? (model.caps?.hostname ?? "") : "No change", text: $model.hostName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .frame(minHeight: AdditionsLayout.touchTarget)
                .background(Desk.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Machine name")
            note("Leave it empty to keep the name.")
        }
        problemsAndWarnings(for: .account)
    }

    private var passwordTitle: String {
        model.accountMode == .existing && model.caps?.account?.passwordSet != true ? "Set a password" : "New password (optional)"
    }

    private func accountModeTitle(_ mode: AdditionsAccountMode) -> String {
        switch mode {
        case .existing: return "Keep \(model.existingName ?? AdditionsPolicy.defaultUser)"
        case .new: return "New account"
        case .unchanged: return "Leave as it is"
        }
    }

    private func accountModeDetail(_ mode: AdditionsAccountMode) -> String {
        switch mode {
        case .existing: return model.caps?.account?.passwordSet == true ? "Change the password and the console sign-in." : "Set a password and the console sign-in."
        case .new: return "Type a name. The guest makes the account."
        case .unchanged: return "The console stays as it is."
        }
    }

    // MARK: Tuxedo Additions

    private var additionsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            card {
                let have = AdditionsPolicy.guestVersion(model.caps)
                Text(model.additionsAction == .update ? "The guest has an older version." : "The guest lacks some of the tools.").font(.headline)
                ForEach(model.additionsChanges, id: \.name) { change in
                    HStack {
                        Text(change.name).font(.system(.body, design: .monospaced))
                        Spacer()
                        Text(change.from.map { "\($0) to \(change.to)" } ?? "Add \(change.to)").foregroundStyle(Desk.dim)
                    }
                    .accessibilityElement(children: .combine)
                }
                if have == nil { note("The guest has no tux-guest yet.") }
                toggle(model.additionsAction == .update ? "Update the tools" : "Install the tools",
                       "The tools come from the app. They need no network.", $model.installAdditions)
            }
        }
    }

    // MARK: Desktop

    private var desktop: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: tileColumns, spacing: AdditionsLayout.gap) {
                ForEach(model.desktopChoices) { c in
                    ChoiceTile(title: c.title, detail: c.detail ?? (c.sizeMB > 0 ? "About \(AdditionsCatalogue.sizeText(c.sizeMB))" : ""),
                               marks: c.marks, selected: c.selected, reason: c.disabledReason) { model.chooseDesktop(c.id) }
                }
            }
            if !model.network { card { warn(AdditionsText.noNetwork, bad: false) } }
            card {
                Text("Console or desktop").font(.headline)
                ForEach(AdditionsText.desktopPoints, id: \.self) { Text($0).font(.subheadline).foregroundStyle(Desk.dim) }
                if let free = model.caps?.diskFreeMB { Text("The machine has \(AdditionsCatalogue.sizeText(free)) free.").font(.subheadline).foregroundStyle(Desk.dim) }
            }
            note("A desktop needs a restart of the machine after it installs.")
        }
    }

    // MARK: Applications

    private var applications: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.network { card { warn(AdditionsText.noNetwork, bad: false) } }
            ForEach(model.catalogue?.appGroups ?? [], id: \.group) { group in
                Text(AdditionsCatalogue.groupTitle(group.group)).font(.title3.weight(.semibold)).padding(.top, 4)
                LazyVGrid(columns: tileColumns, spacing: AdditionsLayout.gap) {
                    ForEach(model.appChoices(group: group.group)) { c in
                        ChoiceTile(title: c.title, detail: "About \(AdditionsCatalogue.sizeText(c.sizeMB))", marks: c.marks, selected: c.selected,
                                   reason: c.disabledReason) { model.toggleApp(c.id) }
                    }
                }
            }
            card {
                toggle("Update the system", model.network ? "Installs the updates Debian has. It can take long." : AdditionsText.noNetwork, $model.systemUpdate)
                    .disabled(!model.network)
            }
        }
    }

    // MARK: SSH

    private var ssh: some View {
        VStack(alignment: .leading, spacing: 16) {
            card { toggle("Turn on SSH", sshNote, $model.sshEnabled) }
            if !model.sshEnabled {
                card {
                    Text("About SSH").font(.headline)
                    ForEach(AdditionsText.sshPoints, id: \.self) { Text($0).font(.subheadline).foregroundStyle(Desk.dim) }
                }
            }
            if model.sshEnabled {
                card {
                    Text("Port").font(.headline)
                    HStack(spacing: 12) {
                        TextField("22", text: $model.sshPortText)
                            .keyboardType(.numberPad)
                            .padding(12)
                            .frame(minHeight: AdditionsLayout.touchTarget)
                            .background(Desk.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .accessibilityLabel("SSH port")
                        portButton("minus", delta: -1, label: "Lower the SSH port by one")
                        portButton("plus", delta: 1, label: "Raise the SSH port by one")
                    }
                    toggle("Allow password login", "Sign in over SSH with the account's password.", $model.sshPasswordLogin)
                    note("Root sign-in over SSH stays off.")
                }
                card {
                    Text("Authorised key").font(.headline)
                    TextEditor(text: $model.sshKey)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 96)
                        .padding(8)
                        .background(Desk.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityLabel("Authorised public key")
                    Button {
                        if let text = UIPasteboard.general.string { model.sshKey = AdditionsPolicy.trimmedKey(text) }
                    } label: { Label("Paste", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity) }
                        .buttonStyle(WizardSecondaryStyle())
                        .accessibilityLabel("Paste a public key from the clipboard")
                    note("Optional. Paste one public key, for example the line from id_ed25519.pub.")
                }
            }
            problemsAndWarnings(for: .ssh)
        }
    }

    /// A round button of 44 pt for the port: the native Stepper is too small to hit.
    private func portButton(_ symbol: String, delta: Int, label: String) -> some View {
        Button { model.stepPort(delta) } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(Desk.accentLight)
                .frame(width: AdditionsLayout.touchTarget, height: AdditionsLayout.touchTarget)
                .background(Desk.raised, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(model.sshPortText)
    }

    private var sshNote: String {
        if let ssh = model.caps?.ssh, !ssh.installed { return "SSH is not installed. The tools install it from the app. No network needed." }
        return "Lets you sign in to the machine from another computer."
    }

    private var portRange: ClosedRange<Int> {
        let l = model.catalogue?.ssh ?? AdditionsCatalogue.SSHLimits()
        return l.portMin...max(l.portMin, l.portMax)
    }

    // MARK: Review

    private var review: some View {
        VStack(alignment: .leading, spacing: 16) {
            card {
                ForEach(Array(model.reviewLines.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.title).font(.headline)
                        if !line.detail.isEmpty { Text(line.detail).font(.subheadline).foregroundStyle(Desk.dim) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
                if model.reviewLines.isEmpty { Text("There is nothing to do yet.").foregroundStyle(Desk.dim) }
            }
            if let estimate = model.estimateText { note(estimate) }
            if model.needsRestart {
                card { toggle("Restart when finished", AdditionsText.restartToggle, $model.restartAfter) }
            }
            problemsAndWarnings(for: .review)
            if !additions.hasMedia {
                card { warn(AdditionsText.notInThisApp, bad: true) }
            } else if let problem = additions.lastError {
                card { warn(problem, bad: true) }
            }
            note(AdditionsText.reviewNote)
        }
    }

    // MARK: Progress

    private var progress: some View {
        let state = additions.state
        return VStack(alignment: .leading, spacing: 16) {
            card {
                ForEach(Array(additions.plan.enumerated()), id: \.offset) { i, title in
                    stepRow(title, state.job?.steps[i])
                }
                if state.job?.steps.isEmpty != false {
                    Text(state.agentReady ? "Starting…" : AdditionsText.waitingForAgent).foregroundStyle(Desk.dim)
                } else if let current = state.job?.currentStep(of: additions.plan.count), let message = state.job?.steps[current]?.message, !message.isEmpty {
                    Text(message).font(.subheadline).foregroundStyle(Desk.dim)
                }
            }
            if let log = state.job?.log, !log.isEmpty {
                DisclosureGroup("Log") {
                    ScrollView {
                        Text(log)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                }
                .padding(16)
                .deskCard()
                .accessibilityLabel("Log of the job")
            }
            Button {
                cancelling = true
                additions.cancel()
            } label: { Text(cancelling ? "Cancelling…" : "Cancel").frame(maxWidth: .infinity) }
                .buttonStyle(WizardSecondaryStyle(destructive: true))
                .disabled(cancelling)
                .accessibilityLabel("Cancel the job")
                .accessibilityHint("The agent stops after the step it runs.")
            if cancelling { note("Cancel takes effect when the running step ends. A download or an install that has started will finish.") }
            note("It is safe to close this page. The job goes on.")
        }
    }

    private func stepRow(_ title: String, _ step: AdditionsJobProgress.Step?) -> some View {
        let (symbol, text, tint): (String, String, Color) = {
            switch step?.status {
            case .none: return ("circle", "Waiting", Desk.faint)
            case .running: return ("arrow.triangle.2.circlepath", "Running", Desk.accentLight)
            case .ok: return ("checkmark.circle.fill", "Done", Desk.good)
            case .failed: return ("xmark.octagon.fill", "Failed", Desk.bad)
            case .skipped: return ("minus.circle", "Skipped", Desk.warn)
            }
        }()
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(text + (step.map { $0.message.isEmpty ? "" : ": " + $0.message } ?? "")).font(.footnote).foregroundStyle(tint)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: AdditionsLayout.touchTarget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(text)")
    }

    // MARK: Done

    private var done: some View {
        let result = additions.state.job?.done
        let ok = result?.ok == true
        return VStack(alignment: .leading, spacing: 16) {
            card {
                HStack(spacing: 12) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.largeTitle).foregroundStyle(ok ? Desk.good : Desk.bad).accessibilityHidden(true)
                    Text(ok ? "All done" : doneTitle).font(.title2.weight(.bold))
                }
                .accessibilityElement(children: .combine)
                if !ok, let failed = failureMessage { Text(failed).font(.body) }
                if result?.reboot == true { warn(model.restartsAfter ? AdditionsText.restartingNote : AdditionsText.restartNote, bad: false) }
            }
            if let info = result?.info {
                if !info.ips.isEmpty { listCard("Addresses", info.ips) }
                if !info.sshFingerprints.isEmpty { listCard("SSH fingerprints", info.sshFingerprints, mono: true) }
                if let user = info.user, !user.isEmpty { note("Account: \(user)") }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { ejectButton; doneButton }
                VStack(spacing: 8) { doneButton; ejectButton }
            }
        }
    }

    /// The heading of a job that did not end well: by how it ended.
    private var doneTitle: String {
        switch additions.state.job?.stopped {
        case .cancelled: return AdditionsText.cancelled
        case .noAnswer: return AdditionsText.noAnswer
        case .badMedia: return "The job did not start"
        case nil: return cancelling ? AdditionsText.cancelled : "The job stopped with an error"
        }
    }

    private var failureMessage: String? {
        switch additions.state.job?.stopped {
        case .noAnswer: return AdditionsText.noAnswerHelp
        case .badMedia(let why): return why
        case .cancelled: return nil
        case nil: break
        }
        guard let job = additions.state.job else { return nil }
        let failed = job.steps.filter { $0.value.status == .failed }.min { $0.key < $1.key }
        guard let (i, step) = failed.map({ ($0.key, $0.value) }) else { return nil }
        let title = additions.plan.indices.contains(i) ? additions.plan[i] : "Step \(i + 1)"
        return step.message.isEmpty ? "\(title) failed." : "\(title) failed: \(step.message)"
    }

    private func listCard(_ title: String, _ items: [String], mono: Bool = false) -> some View {
        card {
            Text(title).font(.headline)
            ForEach(items, id: \.self) { item in
                if mono { FingerprintText(text: item).accessibilityLabel(item) } else { Text(item).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
            }
        }
    }

    private var ejectButton: some View {
        Button {
            additions.eject()
            additions.finishJob()
            close()
        } label: { Text(AdditionsText.ejectShort).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity) }
            .buttonStyle(WizardSecondaryStyle())
            .accessibilityLabel("Eject the Tuxedo Additions CD and close")
    }

    private var doneButton: some View {
        Button(action: closeTapped) { Text("Done") }
            .buttonStyle(WizardPrimaryStyle())
            .accessibilityLabel("Close Tuxedo Additions")
    }

    // MARK: Pieces

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .deskCard()
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(Desk.dim).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func warn(_ text: String, bad: Bool) -> some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: bad ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
        }
        .foregroundStyle(bad ? Desk.bad : Desk.warn)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel((bad ? "Problem: " : "Note: ") + text)
    }

    @ViewBuilder private func problemsAndWarnings(for step: AdditionsStep) -> some View {
        let problems = model.problems(for: step)
        let warnings = step == .review || step == .account ? model.warnings : []
        if !problems.isEmpty || !warnings.isEmpty {
            card {
                ForEach(problems, id: \.self) { warn($0, bad: true) }
                ForEach(warnings, id: \.self) { warn($0, bad: false) }
            }
        }
    }

    private func toggle(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(detail).font(.footnote).foregroundStyle(Desk.dim)
            }
        }
        .tint(Desk.accent)
        .frame(minHeight: AdditionsLayout.touchTarget)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}

/// A fingerprint or an address: monospaced, and it wraps by character with no hyphen. SwiftUI's Text puts a hyphen
/// into a long word it breaks, and a hyphen in a fingerprint reads as part of it. A UITextView does not hyphenate,
/// and its text can be selected and copied exactly.
private struct FingerprintText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byCharWrapping
        view.adjustsFontForContentSizeCategory = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let size = UIFont.preferredFont(forTextStyle: .footnote).pointSize
        view.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: size, weight: .regular))
        view.textColor = .label
        if view.text != text { view.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        return CGSize(width: width, height: uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }
}

/// A label whose icon stays at the top line when the text wraps.
private struct TopIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.icon.frame(width: 20)
            configuration.title.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A tile that is a button: a choice of a desktop, an application or an account. Selected shows a check and a border,
/// and the text says so, so colour is not the only sign.
private struct ChoiceTile: View {
    let title: String
    let detail: String?
    let marks: [String]
    let selected: Bool
    /// nil: the person can pick it. Else why not.
    let reason: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text(title).font(.headline).multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Desk.accentLight : Desk.faint)
                        .accessibilityHidden(true)
                }
                if let detail { Text(detail).font(.subheadline).foregroundStyle(Desk.dim).multilineTextAlignment(.leading) }
                ForEach(reason.map { [$0] } ?? marks, id: \.self) { Text($0).font(.footnote.weight(.semibold)).foregroundStyle(Desk.dim) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .deskCard(radius: 16)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(selected ? Desk.accent : Color.clear, lineWidth: 2))
            .opacity(reason == nil ? 1 : 0.6)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardButtonStyle())
        .disabled(reason != nil)
        .accessibilityLabel(title + (detail.map { ", " + $0 } ?? ""))
        .accessibilityValue(reason ?? (selected ? "Selected" : "Not selected"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The one action of a step: 56 pt high at least, and the text grows with Dynamic Type.
private struct WizardPrimaryStyle: ButtonStyle {
    var enabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(enabled ? Color.white : Desk.dim)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: AdditionsLayout.primaryTarget)
            .background(enabled ? Desk.accent : Desk.raised, in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// A smaller action: 44 pt high at least.
private struct WizardSecondaryStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(destructive ? Desk.bad : Desk.accentLight)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .frame(minHeight: AdditionsLayout.touchTarget)
            .background(Desk.raised, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}
