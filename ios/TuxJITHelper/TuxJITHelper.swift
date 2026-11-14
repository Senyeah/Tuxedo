// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import StikJIT

/// The debugger half of Built-in StikJIT (docs/06-built-in-jit.md).
///
/// A process cannot synchronously debug itself, so Tuxedo starts this extension,
/// sends it its PID, the pairing file and tux-jit.js, and StikJIT attaches over
/// LocalDevVPN and services the script's trap requests until Tuxedo detaches.
private enum TuxJITWork {
    /// One request at a time: enabling JIT holds this queue while the debugger is attached.
    static let queue = DispatchQueue(label: "com.henge.app.jit-helper")

    static func handle(_ request: TuxJITRequest) -> TuxJITRequest.Response {
        let manager = FileManager.default
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
        let paths = DDIPaths.default(in: root)
        var configuration = StikJIT.Configuration.default
        /// Appended to the reply so Tuxedo's log shows how the port was chosen.
        var portNote = ""
        var needsScan = false
        if let rsdPort = request.rsdPort {
            configuration.rsdPort = rsdPort
        } else if request.operation != .resetDDI {
            // Tuxedo found no advertised port. StikJIT's 49152 is closed when the device picked another at boot.
            let lookup = RSDPortResolver.resolve()
            NSLog("[TuxJIT] RemotePairing port: %@", lookup.detail)
            if let port = lookup.port { configuration.rsdPort = port } else { needsScan = true }
            portNote = " [helper port lookup: \(lookup.detail); using \(configuration.rsdPort)]"
        }

        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            if request.operation == .resetDDI {
                try StikJIT.resetCachedDDI(at: paths)
                return .init(success: true, message: "Developer Disk Image cache reset.",
                             txmPresent: StikJIT.isTXMPresent)
            }

            guard let pairingData = request.pairingData, !pairingData.isEmpty else {
                throw NSError(domain: "HengeJITHelper", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The pairing file was not provided."])
            }
            let pairingURL = root.appendingPathComponent("pairingFile-\(UUID().uuidString).plist")
            try pairingData.write(to: pairingURL, options: .atomic)
            defer { try? manager.removeItem(at: pairingURL) }
            if needsScan {
                if let port = findRSDPort(pairingFile: pairingURL, base: configuration) {
                    configuration.rsdPort = port
                    portNote += " [port scan: using \(port)]"
                } else {
                    portNote += " [port scan: no RemotePairing port found]"
                }
            }

            switch request.operation {
            case .prepare:
                let readiness = StikJIT.prepareDevice(
                    pairingFile: pairingURL, paths: paths, configuration: configuration,
                    progress: { NSLog("[TuxJIT] prepare: %@", String(describing: $0)) })
                switch readiness {
                case .ready(let security):
                    return .init(success: true,
                                 message: "LocalDevVPN is reachable and the Developer Disk Image is ready." + portNote,
                                 txmPresent: security.isTXMPresent)
                case .unreachable(let reason), .preparationFailed(let reason):
                    return .init(success: false, message: reason + portNote, txmPresent: StikJIT.isTXMPresent)
                @unknown default:
                    return .init(success: false, message: "StikJIT returned an unknown preparation state.",
                                 txmPresent: StikJIT.isTXMPresent)
                }
            case .enable:
                guard let targetPID = request.targetPID,
                      let scriptBase64 = request.scriptBase64, !scriptBase64.isEmpty else {
                    throw NSError(domain: "HengeJITHelper", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "The target process or Henge's JIT script was not provided."])
                }
                try StikJIT.enableJIT(
                    targetPID: targetPID,
                    pairingFile: pairingURL,
                    ddiPaths: paths,
                    configuration: configuration,
                    script: .customBase64(scriptBase64),
                    forceScript: true,
                    preparationProgress: { NSLog("[TuxJIT] prepare: %@", String(describing: $0)) },
                    progress: { NSLog("[TuxJIT] %@", $0) })
                return .init(success: true, message: "Henge detached cleanly from its built-in JIT helper." + portNote,
                             txmPresent: StikJIT.isTXMPresent)
            case .resetDDI:
                preconditionFailure("Handled above")
            }
        } catch {
            return .init(success: false, message: error.localizedDescription + portNote,
                         txmPresent: StikJIT.isTXMPresent)
        }
    }

    private static let lastPortKey = "henge.lastRSDPort"

    /// The last port that worked, then every open port in iOS's range, each probed with a real StikJIT call.
    /// The port changes at each reboot of the device, so a stale remembered one just falls through to the scan.
    private static func findRSDPort(pairingFile: URL, base: StikJIT.Configuration) -> UInt16? {
        func works(_ port: UInt16) -> Bool {
            var probe = base
            probe.rsdPort = port
            probe.connectionTimeout = 2
            return (try? StikJIT.isDDIMounted(pairingFile: pairingFile, configuration: probe)) != nil
        }
        let last = UInt16(exactly: UserDefaults.standard.integer(forKey: lastPortKey)) ?? 0
        if last != 0, works(last) { return last }
        let open = RSDPortScanner.openPorts(host: base.deviceAddress)
        NSLog("[TuxJIT] open ports: %@", open.map(String.init).joined(separator: ","))
        guard let port = open.first(where: works) else { return nil }
        UserDefaults.standard.set(Int(port), forKey: lastPortKey)
        return port
    }
}

/// NSExtensionPrincipalClass (Info.plist). The request arrives as JSON in the
/// first input item; the response goes back as JSON in the item the request
/// completes with. Enable completes only once Tuxedo's script has detached, so
/// the request, and this process, last as long as the debugger does.
@objc(TuxJITHelperHandler)
final class TuxJITHelperHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let info = (context.inputItems.first as? NSExtensionItem)?.userInfo
        let data = info?[TuxJITRequest.itemKey] as? Data
        TuxJITWork.queue.async {
            let response: TuxJITRequest.Response
            if let data, let request = try? JSONDecoder().decode(TuxJITRequest.self, from: data) {
                response = TuxJITWork.handle(request)
            } else {
                response = .init(success: false, message: "Henge's JIT helper received no request.",
                                 txmPresent: nil)
            }
            let item = NSExtensionItem()
            item.userInfo = [TuxJITRequest.Response.itemKey: (try? JSONEncoder().encode(response)) ?? Data()]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}
