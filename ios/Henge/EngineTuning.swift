import Foundation

/// Engine settings, without a rebuild. Defaults below, then the Performance settings,
/// then Documents/henge-env.txt (KEY=VALUE per line, # comments; {Documents} in a value is that folder) overrides them all.
/// Applied at launch and again before each machine starts, so changes need no relaunch.
enum EngineTuning {
    static let superblocksKey = "henge.perf.superblocks"
    static let wfiSpinKey = "henge.perf.wfiSpin"
    static let fastFlushKey = "henge.perf.fastFlush"

    static let defaults: [String: String] = [
        "HV_WFI_SPIN": "0",    // microseconds an idle CPU watches for work before sleeping
        "HV_FLUSH": "2",       // disk flush: F_BARRIERFSYNC, ordered but without a full fsync
        "HV_STATS": "10",      // seconds between engine stats lines in the log; 0 = off
    ]

    static func apply() {
        var env = defaults
        let d = UserDefaults.standard
        if d.bool(forKey: superblocksKey) { env["HV_SUPERBLOCKS"] = "1" } else { unsetenv("HV_SUPERBLOCKS") }
        if d.bool(forKey: wfiSpinKey) { env["HV_WFI_SPIN"] = "50" }
        if d.object(forKey: fastFlushKey) as? Bool == false { env["HV_FLUSH"] = "0" }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("henge-env.txt")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                guard let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
                // {Documents} stands for this folder: its absolute path changes when Tuxedo is reinstalled.
                env[String(line[..<eq]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: eq)...])
                    .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "{Documents}", with: docs.path)
            }
        }
        for (k, v) in env.sorted(by: { $0.key < $1.key }) {
            setenv(k, v, 1)
            HengeLog.log("tuning", "\(k)=\(v)")
        }
    }
}
