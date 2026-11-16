// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The events the guest's agent sends (docs/guest-additions-design.md, 5.3) and the app's replay of them into a state.
/// Pure: no engine. The engine's hv_additions_events_json gives the text.
enum AdditionsStepStatus: String, Equatable {
    case running, ok, failed, skipped

    var finished: Bool { self != .running }
}

struct AdditionsDoneInfo: Equatable {
    var ips: [String] = []
    var sshFingerprints: [String] = []
    var user: String?
}

enum AdditionsEvent: Equatable {
    case report(AdditionsReport)
    case ack(job: String)
    case step(job: String, index: Int, status: AdditionsStepStatus, message: String)
    case log(job: String, text: String)
    case done(job: String, ok: Bool, reboot: Bool, info: AdditionsDoneInfo)
    case badMedia(n: Int, why: String)
}

/// One answer of hv_additions_events_json (design 5.6).
struct AdditionsFeed: Equatable {
    var inserted = false
    var n = 0
    var seq: UInt64 = 0
    var gap = false
    var events: [(k: UInt64, event: AdditionsEvent)] = []
    /// The largest k of every item the host sent, also the ones this app does not know.
    private var seenK: UInt64 = 0

    static func == (a: AdditionsFeed, b: AdditionsFeed) -> Bool {
        a.inserted == b.inserted && a.n == b.n && a.seq == b.seq && a.gap == b.gap
            && a.events.map(\.k) == b.events.map(\.k) && a.events.map(\.event) == b.events.map(\.event)
    }

    /// What the next poll asks after. An event that is left out still counts, so it is not fetched again.
    var lastK: UInt64 { max(seenK, events.last?.k ?? 0) }

    /// nil when the text is not a JSON object. An event of an unknown type, or of the wrong shape, is left out: the
    /// guest may be newer than the app. The host has checked the JSON; the app only reads it.
    static func decode(_ text: String) -> AdditionsFeed? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        var feed = AdditionsFeed()
        feed.inserted = object["inserted"] as? Bool ?? false
        feed.n = object["n"] as? Int ?? 0
        feed.seq = (object["seq"] as? NSNumber)?.uint64Value ?? 0
        feed.gap = object["gap"] as? Bool ?? false
        for item in (object["events"] as? [[String: Any]]) ?? [] {
            guard let k = (item["k"] as? NSNumber)?.uint64Value else { continue }
            feed.seenK = max(feed.seenK, k)
            guard let e = item["e"] as? [String: Any], let event = decodeEvent(e) else { continue }
            feed.events.append((k, event))
        }
        return feed
    }

    private static func decodeEvent(_ e: [String: Any]) -> AdditionsEvent? {
        guard let t = e["t"] as? String else { return nil }
        switch t {
        case "report":
            guard let data = try? JSONSerialization.data(withJSONObject: e),
                  let report = try? JSONDecoder().decode(AdditionsReport.self, from: data) else { return nil }
            return .report(report)
        case "ack":
            guard let job = e["job"] as? String else { return nil }
            return .ack(job: job)
        case "step":
            guard let job = e["job"] as? String, let i = e["i"] as? Int, i >= 0,
                  let status = (e["status"] as? String).flatMap(AdditionsStepStatus.init(rawValue:)) else { return nil }
            return .step(job: job, index: i, status: status, message: e["msg"] as? String ?? "")
        case "log":
            guard let job = e["job"] as? String, let text = e["text"] as? String else { return nil }
            return .log(job: job, text: text)
        case "done":
            guard let job = e["job"] as? String else { return nil }
            let info = e["info"] as? [String: Any] ?? [:]
            return .done(job: job, ok: e["ok"] as? Bool ?? false, reboot: e["reboot"] as? Bool ?? false,
                         info: AdditionsDoneInfo(ips: strings(info["ips"]), sshFingerprints: strings(info["ssh_fingerprints"]),
                                                 user: info["user"] as? String))
        case "bad-media":
            return .badMedia(n: e["n"] as? Int ?? 0, why: e["why"] as? String ?? "")
        case "launch-error": // the guest could not start the agent (for example a full disk): same end as bad media
            let why = e["why"] as? String ?? ""
            return .badMedia(n: e["n"] as? Int ?? 0, why: "The guest could not start the installer" + (why.isEmpty ? "." : ": " + why))
        default:
            return nil
        }
    }

    private static func strings(_ value: Any?) -> [String] { (value as? [Any])?.compactMap { $0 as? String } ?? [] }
}

/// What the agent did in one job, as the events tell it.
struct AdditionsJobProgress: Equatable {
    struct Step: Equatable {
        var status: AdditionsStepStatus
        var message: String
    }

    var id: String
    /// The app set this job itself (the events of another job are not this one's).
    var local = false
    var steps: [Int: Step] = [:]
    var log = ""
    var done: Done?
    /// The agent has the job: it posted ack, or any event of the job. The host no longer holds the job then.
    var taken = false
    /// The job ended with no done from the agent (the agent never took it, or never answered).
    var stopped: Stop?

    enum Stop: Equatable {
        /// The person cancelled before the agent took the job: the engine forgot it and nobody posts done.
        case cancelled
        /// No ack and no step in time.
        case noAnswer
        /// The launcher refused the media.
        case badMedia(String)
    }

    /// Nothing more will come from the agent, or the person cancelled before it took the job.
    var over: Bool { done != nil || stopped != nil }

    struct Done: Equatable {
        var ok: Bool
        var reboot: Bool
        var info: AdditionsDoneInfo
    }

    /// The step that runs now, or the first with no word yet.
    func currentStep(of count: Int) -> Int? {
        if let running = steps.first(where: { $0.value.status == .running })?.key { return running }
        return (0..<count).first { steps[$0] == nil }
    }
}

/// The app's view of the guest's agent: the last report, and the progress of the job. Events apply once, in order.
struct AdditionsState: Equatable {
    static let logLimit = 64 * 1024

    var inserted = false
    var n = 0
    /// The newest event applied; the next poll asks for the ones after it.
    var lastK: UInt64 = 0
    var report: AdditionsReport?
    var job: AdditionsJobProgress?
    /// The launcher refused the media; a new report clears it.
    var badMedia: String?
    /// The last answer said the app missed events.
    var gap = false

    var caps: AdditionsCaps? { report?.caps }
    /// A job the app set that is not over: not done, not cancelled before pickup, not refused, not timed out.
    var running: Bool { job.map { !$0.over } ?? false }

    /// The agent that runs now has reported for this insert (a report from boot has an older n).
    var agentReady: Bool { inserted && n > 0 && (report?.n ?? 0) >= n }

    mutating func apply(_ feed: AdditionsFeed) {
        inserted = feed.inserted
        n = feed.n
        gap = feed.gap
        for (k, event) in feed.events where k > lastK {
            lastK = k
            apply(event)
        }
        lastK = max(lastK, feed.lastK)
    }

    mutating func apply(_ event: AdditionsEvent) {
        switch event {
        case .report(let r):
            report = r
            badMedia = nil
        case .ack(let id):
            guard track(id) else { return }
            job?.taken = true
        case .step(let id, let i, let status, let message):
            guard track(id) else { return }
            job?.taken = true
            job?.steps[i] = .init(status: status, message: message)
        case .log(let id, let text):
            guard track(id) else { return }
            job?.taken = true
            job?.log += text
            if let over = job.map({ $0.log.count - Self.logLimit }), over > 0 { job?.log.removeFirst(over) }
        case .done(let id, let ok, let reboot, let info):
            guard track(id) else { return }
            job?.taken = true
            job?.done = .init(ok: ok, reboot: reboot, info: info)
        case .badMedia(_, let why):
            let text = why.isEmpty ? AdditionsText.badMedia : why
            badMedia = text
            _ = abandon(.badMedia(text)) // the launcher refused the media: the agent never runs, so no done will come
        }
    }

    /// The app's own job ends with no word from the agent. Only a job the agent has not taken: after the ack the agent
    /// owns it and posts done. true when the job was running.
    @discardableResult
    mutating func abandon(_ why: AdditionsJobProgress.Stop) -> Bool {
        guard var current = job, current.local, !current.over, !current.taken else { return false }
        current.stopped = why
        job = current
        return true
    }

    /// The job the events belong to: a new id starts a new progress, unless the app's own job is waiting for its
    /// events (a late event of an older job is not shown).
    private mutating func track(_ id: String) -> Bool {
        if let job, job.id == id { return true }
        if let job, job.local, !job.over { return false }
        job = AdditionsJobProgress(id: id)
        return true
    }

    /// The app sets a job: the progress starts empty and follows this id.
    mutating func beginJob(id: String) {
        job = AdditionsJobProgress(id: id, local: true)
    }

    /// The person leaves the finished job's page.
    mutating func clearJob() { job = nil }
}
