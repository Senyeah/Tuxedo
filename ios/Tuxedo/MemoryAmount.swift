// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A machine's memory as the user types it, in GB. Stored in MB.
enum MemoryAmount {
    /// GuestMemory.prepare rounds the guest's RAM down to this, so a finer size would silently shrink.
    static let stepMB = 512
    static let minMB = 1024
    static let maxMB = 16 * 1024

    enum Problem: Error, Equatable {
        case empty, notANumber, tooSmall, tooLarge, notAStep

        var message: String {
            switch self {
            case .empty: return "Enter a size in GB."
            case .notANumber: return "Use numbers only, such as 1.5."
            case .tooSmall: return "The least is \(MemoryAmount.text(MemoryAmount.minMB)) GB."
            case .tooLarge: return "The most is \(MemoryAmount.text(MemoryAmount.maxMB)) GB."
            case .notAStep: return "Use steps of \(MemoryAmount.text(MemoryAmount.stepMB)) GB, such as 1.5 or 2."
            }
        }
    }

    /// MB for the text, or what is wrong with it. Accepts "1.5", "1,5", "2 GB".
    static func parse(_ raw: String) -> Result<Int, Problem> {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasSuffix("gb") { text = String(text.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        if text.isEmpty { return .failure(.empty) }
        text = text.replacingOccurrences(of: ",", with: ".")
        // Double() also takes "inf", "nan", exponents and hex floats.
        guard text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), text.filter({ $0 == "." }).count <= 1,
              text.contains(where: \.isNumber), let gb = Double(text) else { return .failure(.notANumber) }
        let mb = gb * 1024
        if mb < Double(minMB) { return .failure(.tooSmall) }
        if mb > Double(maxMB) { return .failure(.tooLarge) }
        let steps = (mb / Double(stepMB)).rounded()
        if abs(mb - steps * Double(stepMB)) > 0.01 { return .failure(.notAStep) }
        return .success(Int(steps) * stepMB)
    }

    /// GB for the field and the machine list: "2", "1.5".
    static func text(_ mb: Int) -> String {
        if mb % 1024 == 0 { return "\(mb / 1024)" }
        return String(format: "%g", (Double(mb) / 1024 * 100).rounded() / 100)
    }

    static func clamped(_ mb: Int) -> Int { min(max(mb, minMB), maxMB) }
}
