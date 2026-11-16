// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main
struct MemoryAmountTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }

    static func ok(_ text: String, _ mb: Int) {
        check(MemoryAmount.parse(text) == .success(mb), "\(text) should be \(mb) MB, got \(MemoryAmount.parse(text))")
    }

    static func bad(_ text: String, _ problem: MemoryAmount.Problem) {
        check(MemoryAmount.parse(text) == .failure(problem), "\(text) should fail with \(problem), got \(MemoryAmount.parse(text))")
    }

    static func main() {
        ok("1", 1024); ok("1.5", 1536); ok("1,5", 1536); ok("2", 2048); ok(" 2 GB ", 2048); ok("2gb", 2048)
        ok("1.50", 1536); ok("16", 16384); ok("01.5", 1536); ok("1.", 1024); ok("2.5", 2560)

        bad("", .empty); bad("   ", .empty)
        bad("abc", .notANumber); bad("1.5.5", .notANumber); bad(".", .notANumber); bad("-1", .notANumber)
        bad("1e1", .notANumber); bad("inf", .notANumber); bad("nan", .notANumber); bad("0x10", .notANumber); bad("١", .notANumber)
        bad("0.5", .tooSmall); bad("0", .tooSmall); bad("0.99", .tooSmall)
        bad("16.5", .tooLarge); bad("17", .tooLarge); bad("1000", .tooLarge)
        bad("1.25", .notAStep); bad("1.1", .notAStep); bad("2.75", .notAStep)

        check(MemoryAmount.text(1024) == "1" && MemoryAmount.text(1536) == "1.5" && MemoryAmount.text(2048) == "2", "text")
        check(MemoryAmount.text(16384) == "16" && MemoryAmount.text(4608) == "4.5", "text")
        for mb in stride(from: MemoryAmount.minMB, through: MemoryAmount.maxMB, by: MemoryAmount.stepMB) {
            ok(MemoryAmount.text(mb), mb)
        }
        check(MemoryAmount.clamped(0) == 1024 && MemoryAmount.clamped(99999) == 16384 && MemoryAmount.clamped(1536) == 1536, "clamp")
        print("memory amount: ok")
    }
}
