import SwiftUI

/// A request to show the wizard: from the Details button, or from the account prompt.
struct AdditionsWizardRequest: Identifiable, Equatable {
    let id = UUID()
    /// nil: the first step.
    var step: AdditionsStep?
    /// The account step opens with the question (Set up, Not now).
    var intro = false
}

/// A running session's Tuxedo Additions: the media in the guest, the agent's events replayed into a state, the job,
/// and the account prompt. One for each session. The engine's calls are in host/additions.h.
@MainActor
final class TuxAdditions: ObservableObject {
    @Published private(set) var state = AdditionsState()
    /// The titles of the steps of the job the app set, for the progress list. The job itself, with its password, is not kept.
    @Published private(set) var plan: [String] = []
    @Published private(set) var lastError: String?
    /// The account prompt wants the wizard on screen (SessionView shows it).
    @Published private(set) var promptRequest: AdditionsWizardRequest?

    /// The bundled media: Tuxedo.app/TuxAdditions (a copy of build/linux/additions/tux-additions, made by the build:
    /// see "Copy Tuxedo Additions" in project.yml). nil in a build with no media.
    nonisolated static var mediaURL: URL? { Bundle.main.url(forResource: "TuxAdditions", withExtension: nil) }

    let versions: AdditionsVersions?
    let catalogue: AdditionsCatalogue?
    /// The picture of the wizard with no machine (Autopilot additions-demo): no engine, no media.
    private let isDemo: Bool
    /// The build carries the media and its versions.json reads. Without it nothing here starts: no prompt, no job.
    var hasMedia: Bool { isDemo || (Self.mediaURL != nil && versions != nil) }

    private var machine: UUID?
    private var poller: Poller?
    private var trigger = AdditionsPolicy.Trigger()
    private var lastNudge: Date?
    /// The step of the job that sets up the account, and the name it sets; saved as guestUser when that step is ok.
    private var accountStep: (index: Int, name: String)?
    private var startTimer: Task<Void, Never>?

    init() {
        isDemo = false
        func read(_ name: String) -> Data? { Self.mediaURL.flatMap { try? Data(contentsOf: $0.appendingPathComponent(name)) } }
        versions = read("versions.json").flatMap(AdditionsVersions.decode)
        catalogue = read("actions.json").flatMap(AdditionsCatalogue.decode)
    }

    /// For a picture of the wizard with no machine (Autopilot additions-demo): the media and the report are given.
    init(demo report: AdditionsReport, versions: AdditionsVersions?, catalogue: AdditionsCatalogue?) {
        self.versions = versions
        self.catalogue = catalogue
        isDemo = true
        state.inserted = true
        state.n = 1
        state.report = report
    }

    deinit {
        poller?.stop()
        startTimer?.cancel()
    }

    // MARK: The session

    /// After the machine booted: the poll starts at sequence 0, so the reports the guest sent before this view looked
    /// (tux-status at boot) are seen.
    func begin(_ machine: VirtualMachine) {
        stop()
        self.machine = machine.id
        state = AdditionsState()
        plan = []
        lastError = nil
        promptRequest = nil
        lastNudge = nil
        accountStep = nil
        trigger.reset()
        poller = Poller { [weak self] feed in
            Task { @MainActor in self?.receive(feed) }
        }
    }

    /// The machine stopped or the session closed. The job leaves the engine's memory.
    func stop() {
        poller?.stop()
        poller = nil
        startTimer?.cancel()
        startTimer = nil
        machine = nil
        hv_additions_job_clear()
        state = AdditionsState()
        plan = []
        promptRequest = nil
        accountStep = nil
    }

    var running: Bool { poller != nil }

    // MARK: The media

    /// The engine's own word, not the polled state (which lags): the media is in.
    var engineInserted: Bool { isDemo || hv_additions_inserted() > 0 }

    /// Puts the media in once. The guest starts its agent by itself. With the media already in it does nothing and says
    /// true, so a second caller (the prompt, then the wizard) cannot add a second n. false: no media, or it did not open.
    @discardableResult
    func insert() -> Bool {
        guard hasMedia else {
            lastError = AdditionsText.notInThisApp
            return false
        }
        if engineInserted { return true }
        guard let url = Self.mediaURL else { return false }
        let n = url.path.withCString { hv_additions_insert($0) }
        let why = String(cString: strerror(errno)) // before anything else can change errno
        guard n > 0 else {
            lastError = "The media did not open (\(why))."
            TuxLog.log("additions", "insert failed: \(why)")
            return false
        }
        lastError = nil
        TuxLog.log("additions", "media in, n=\(n)")
        return true
    }

    func eject() {
        hv_additions_eject()
        TuxLog.log("additions", "media out")
    }

    /// The guest starts its agent again, and the agent sends a new report. It stops a job that runs.
    func nudge() {
        guard !isDemo, engineInserted, !state.running else { return }
        if hv_additions_nudge() > 0 { lastNudge = Date() }
    }

    /// "Ask the guest again": a new agent when the media is in, else the media goes in.
    func askAgain() {
        if engineInserted { nudge() } else { insert() }
    }

    var inserted: Bool { state.inserted }

    // MARK: The job

    /// Gives the job to the agent. The password goes in the engine's memory and is not kept here. Never with no media or
    /// with the media out: no agent would run it.
    @discardableResult
    func start(job: AdditionsJob) -> Bool {
        guard hasMedia else {
            lastError = AdditionsText.notInThisApp
            return false
        }
        guard engineInserted else {
            lastError = AdditionsText.notInserted
            return false
        }
        guard var bytes = job.jsonBytes() else {
            lastError = "The job is too big or empty."
            return false
        }
        defer { bytes.withUnsafeMutableBytes { hv_additions_wipe($0.baseAddress, $0.count) } }
        state.beginJob(id: job.id) // first: a late event of the last job is not this one's
        let rc = bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { hv_additions_job_set($0) }
        }
        let why = String(cString: strerror(errno))
        guard rc == 0 else {
            state.clearJob()
            lastError = "The engine did not accept the job."
            TuxLog.log("additions", "job_set failed: \(why)")
            return false
        }
        lastError = nil
        plan = job.steps.map { $0.title(catalogue) }
        if let i = job.accountStepIndex, let name = job.accountName { accountStep = (i, name) } else { accountStep = nil }
        if AdditionsPolicy.leavesAccountUnset(job: job.accountName, caps: state.caps) { dismissPrompt() } // the person chose to leave it
        armStartTimer(job.id)
        TuxLog.log("additions", "\(job) set") // the job's description holds no password
        return true
    }

    /// No ack and no step in time: the agent is not there. The engine forgets the job, and the page shows it.
    private func armStartTimer(_ id: String) {
        startTimer?.cancel()
        startTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AdditionsPolicy.jobStartTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.startTimedOut(id)
        }
    }

    private func startTimedOut(_ id: String) {
        guard state.job?.id == id, state.abandon(.noAnswer) else { return }
        hv_additions_job_cancel() // wipes the job: the password does not wait for an agent that is not there
        TuxLog.log("additions", "the guest did not answer: job cancelled")
    }

    /// The agent stops after the step it runs and posts done. Before the agent took the job nobody posts done: the
    /// engine wipes the job and the app marks it cancelled at once.
    func cancel() {
        hv_additions_job_cancel()
        state.abandon(.cancelled)
        TuxLog.log("additions", "job cancelled")
    }

    /// The person leaves the Done page.
    func finishJob() {
        startTimer?.cancel()
        startTimer = nil
        state.clearJob()
        plan = []
        accountStep = nil
    }

    // MARK: The prompt

    /// The wizard is open (from a tap or the prompt): the account prompt has nothing left to ask this session. A job
    /// that ended with no done (cancelled, refused, no answer) is dead: a wizard that does not show it drops it.
    func wizardOpened(showingJob: Bool) {
        trigger.consume()
        promptRequest = nil
        if !showingJob, state.job?.stopped != nil {
            state.clearJob()
            plan = []
            accountStep = nil
        }
    }

    /// Not now on the prompt.
    func dismissPrompt() {
        guard let machine else { return }
        Machines.shared.updateAdditions(of: machine) { $0.additionsPromptDismissed = true }
    }

    var promptDismissed: Bool {
        guard let machine else { return false }
        return Machines.shared.all.first { $0.id == machine }?.additionsPromptDismissed == true
    }

    // MARK: Events

    private func receive(_ feed: AdditionsFeed) {
        guard machine != nil else { return }
        let before = state.report
        let wasRunning = state.running
        state.apply(feed)
        if wasRunning, state.job?.stopped != nil { hv_additions_job_clear() } // the launcher refused the media: no agent has the job
        if state.report != before, let report = state.report { save(report) }
        saveGuestUser()
        evaluatePrompt()
        if AdditionsPolicy.shouldNudge(gap: state.gap, inserted: state.inserted, jobRunning: state.running, lastNudge: lastNudge, now: Date()) {
            TuxLog.log("additions", "events missed: asking for a new report")
            nudge()
        }
    }

    private func save(_ report: AdditionsReport) {
        guard let machine else { return }
        Machines.shared.updateAdditions(of: machine) { $0.additionsReport = report }
    }

    /// After a good user.setup: the name of an account that is not tux goes in the machine's record.
    private func saveGuestUser() {
        guard let machine, let (index, name) = accountStep, state.job?.steps[index]?.status == .ok else { return }
        accountStep = nil
        Machines.shared.updateAdditions(of: machine) { m in
            if let user = AdditionsPolicy.guestUserUpdate(name: name, current: m.guestUser) { m.guestUser = user }
        }
    }

    private func evaluatePrompt() {
        guard promptRequest == nil, hasMedia, trigger.shouldFire(report: state.report, dismissed: promptDismissed) else { return }
        guard insert() else { // no media or it did not open: no wizard (Details says why)
            TuxLog.log("additions", "the account is not set up, but the media is not in: no prompt")
            return
        }
        TuxLog.log("additions", "the account is not set up: showing the prompt")
        promptRequest = AdditionsWizardRequest(step: .account, intro: true)
    }
}

/// Reads the engine's events on its own thread and hands each answer to the main actor. A thread, not a task:
/// hv_additions_wait blocks.
private final class Poller {
    private let lock = NSLock()
    private var cancelled = false

    init(deliver: @escaping (AdditionsFeed) -> Void) {
        Thread.detachNewThread { [self] in loop(deliver) }
    }

    func stop() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func loop(_ deliver: (AdditionsFeed) -> Void) {
        Thread.current.name = "tux-additions"
        var since: UInt = 0 // the last event key seen: not the count hv_additions_wait takes
        var sent: (inserted: Bool, n: Int, gap: Bool)?
        while !isCancelled {
            var seq: UInt = 0
            guard let raw = hv_additions_events_json(since, &seq) else {
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            let text = String(cString: raw)
            free(raw)
            if let feed = AdditionsFeed.decode(text) {
                since = max(since, UInt(feed.lastK))
                let header = (feed.inserted, feed.n, feed.gap)
                if sent == nil || !feed.events.isEmpty || sent! != header {
                    sent = header
                    deliver(feed)
                }
            }
            let started = Date()
            _ = hv_additions_wait(seq, 500)
            if Date().timeIntervalSince(started) < 0.02 { Thread.sleep(forTimeInterval: 0.1) } // a wait that returns at once must not spin
        }
    }
}
