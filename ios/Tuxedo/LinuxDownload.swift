import Foundation

/// Fetches a catalogue entry's firmware and disk into one folder, checking each against the catalogue's SHA-256.
enum LinuxDownload {
    /// The firmware is small: its check counts as part of the download step.
    enum Stage { case download, check, checkFirmware }

    struct Files { var disk: URL; var firmware: URL }

    static let folderName = "Linux images"
    static let source = "The image server"
    /// The app points this at henge.log; tests leave it silent.
    nonisolated(unsafe) static var log: @Sendable (String) -> Void = { _ in }

    static func folder(root: URL) -> URL { root.appendingPathComponent(folderName, isDirectory: true) }

    /// A file only gets its final name after its hash matched, so a final name means a good file.
    static func files(_ image: LinuxImage, in dir: URL) -> Files {
        Files(disk: dir.appendingPathComponent("\(image.id)-\(image.version).hvsparse.lzfse"),
              firmware: dir.appendingPathComponent("u-boot-\(image.firmwareSHA256.prefix(12)).bin"))
    }

    static func haveAll(_ image: LinuxImage, in dir: URL) -> Bool {
        let f = files(image, in: dir)
        return image.diskBytes > 0 && image.firmwareBytes > 0
            && size(f.disk) == image.diskBytes && size(f.firmware) == image.firmwareBytes
    }

    /// Bytes of this entry already on the device, whole files and parts.
    static func present(_ image: LinuxImage, in dir: URL) -> Int64 {
        let f = files(image, in: dir)
        func have(_ url: URL, _ whole: Int64) -> Int64 {
            let n = size(url)
            return n > 0 ? min(n, whole) : min(RangedDownload.size(of: url.appendingPathExtension("part")), whole)
        }
        return have(f.disk, image.diskBytes) + have(f.firmware, image.firmwareBytes)
    }

    /// `others` are the other entries: firmware another one still uses stays.
    static func delete(_ image: LinuxImage, in dir: URL, others: [LinuxImage] = []) {
        let f = files(image, in: dir)
        let shared = others.contains { $0.id != image.id && files($0, in: dir).firmware == f.firmware }
        for u in shared ? [f.disk] : [f.disk, f.firmware] {
            try? FileManager.default.removeItem(at: u)
            try? FileManager.default.removeItem(at: u.appendingPathExtension("part"))
        }
    }

    private static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// `progress` gets the stage and the bytes done and expected across both files.
    static func fetch(_ image: LinuxImage, in dir: URL, progress: @escaping @Sendable (Stage, Int64, Int64) -> Void) async throws -> Files {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = files(image, in: dir)
        let total = image.downloadBytes
        var base: Int64 = 0
        for (url, dest, bytes, sha, what) in [(image.firmwareURL, f.firmware, image.firmwareBytes, image.firmwareSHA256, "firmware"),
                                              (image.diskURL, f.disk, image.diskBytes, image.diskSHA256, "disk")] {
            let offset = base
            if bytes > 0 && size(dest) == bytes {
                base += bytes
                progress(.download, base, total)
                continue
            }
            try? FileManager.default.removeItem(at: dest)
            let part = dest.appendingPathExtension("part")
            try await download(url, part: part) { have in progress(.download, offset + have, total) }
            let stage: Stage = what == "firmware" ? .checkFirmware : .check
            try FileHash.verify(part, expected: sha, what: what) { done in progress(stage, offset + done, total) }
            try FileManager.default.moveItem(at: part, to: dest)
            base += bytes
        }
        return f
    }

    /// Goes on after an interruption (no network, the server stopped) from where the part ends.
    private static func download(_ url: URL, part: URL, have: @escaping @Sendable (Int64) -> Void) async throws {
        for attempt in 1...20 {
            let d = RangedDownload(url: url, part: part, source: source) { n, _ in have(n) }
            do {
                try await d.run()
                return
            } catch let error as NSError {
                // A refusal (status, wrong range, no file) does not get better by waiting.
                let refused = error.domain == "Henge" && (error.code == 3 || error.code == 4 || error.code == 5)
                if Task.isCancelled || attempt == 20 || refused { throw error }
                log("download interrupted (\(error.localizedDescription)) at \(RangedDownload.size(of: part)) bytes; going on")
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}
