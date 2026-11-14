import Foundation
import UIKit

/// Where AssistiveTouch's pointer is, from the HID events UIKit sees (private API, docs/mouse-capture-ios.md).
/// Each pointer report is a digitizer event with a pointer child (type 17) whose X and Y fields hold the
/// position, already held inside the phone's screen. EdgePush uses it to see that the pointer is at an edge.
/// With Documents/henge-mouse-probe present it also logs a summary each second.
enum PointerWatch {
    /// Called on the main queue with each position, in the system's own axes.
    static var onPosition: ((Double, Double) -> Void)?
    private static var started = false

    private typealias GetType = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias GetFloat = @convention(c) (UnsafeMutableRawPointer, UInt32) -> Double
    private typealias GetChildren = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
    private typealias SetObserver = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void

    private static var logging = false
    private static var types: [Int32: Int] = [:]
    private static var positions = 0, logged = 0, last = Date()

    static func start() {
        guard !started else { return }
        started = true
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logging = FileManager.default.fileExists(atPath: docs.appendingPathComponent("henge-mouse-probe").path)
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let tp = dlsym(rtldDefault, "IOHIDEventGetType"), let fp = dlsym(rtldDefault, "IOHIDEventGetFloatValue"),
              let cp = dlsym(rtldDefault, "IOHIDEventGetChildren") else {
            TuxLog.log("input", "pointer watch: no IOHIDEvent functions")
            return
        }
        let getType = unsafeBitCast(tp, to: GetType.self), getFloat = unsafeBitCast(fp, to: GetFloat.self)
        let getChildren = unsafeBitCast(cp, to: GetChildren.self)

        func pointer(in e: UnsafeMutableRawPointer, depth: Int) -> UnsafeMutableRawPointer? {
            let t = getType(e)
            if logging { types[t, default: 0] += 1 }
            if t == 17 { return e }
            guard depth < 2, let kids = getChildren(e)?.takeUnretainedValue() as? [AnyObject] else { return nil }
            for k in kids {
                if let p = pointer(in: Unmanaged.passUnretained(k).toOpaque(), depth: depth + 1) { return p }
            }
            return nil
        }
        let observer: @convention(block) (UnsafeMutableRawPointer?) -> Void = { e in
            guard let e, let p = pointer(in: e, depth: 0) else { return }
            let x = getFloat(p, 0x110000), y = getFloat(p, 0x110001)
            onPosition?(x, y)
            guard logging else { return }
            positions += 1
            if logged < 30 { logged += 1; TuxLog.log("input", "pointer watch: \(x), \(y)") }
            guard Date().timeIntervalSince(last) >= 1 else { return }
            TuxLog.log("input", "pointer watch: \(positions) positions, last \(Int(x)),\(Int(y)), types \(types.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))")
            types = [:]
            positions = 0
            last = Date()
        }
        let sel = NSSelectorFromString("_setHIDEventObserver:onQueue:")
        guard UIApplication.shared.responds(to: sel) else {
            TuxLog.log("input", "pointer watch: no _setHIDEventObserver:onQueue:")
            return
        }
        let set = unsafeBitCast(UIApplication.shared.method(for: sel), to: SetObserver.self)
        set(UIApplication.shared, sel, unsafeBitCast(observer, to: AnyObject.self), DispatchQueue.main)
        TuxLog.log("input", "pointer watch: on")
    }
}
