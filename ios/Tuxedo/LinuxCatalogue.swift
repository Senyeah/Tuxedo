// SPDX-License-Identifier: GPL-2.0-or-later
import CryptoKit
import Foundation

/// One downloadable Linux machine image, as tools/linux/package-image.sh describes it in linux-images.json.
struct LinuxImage: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var version: String
    var kind: String
    var diskURL: URL
    var diskBytes: Int64
    var diskSHA256: String
    /// The disk's .hvsparse once decoded, before hv_sparse_unpack.
    var unpackedBytes: Int64
    var logicalBytes: Int64
    var firmwareURL: URL
    var firmwareBytes: Int64
    var firmwareSHA256: String
    var kernel: String?
    var minBuild: Int?
    /// A machine made from it starts in touch mode (LINUX-PLAN-12 decision 8: a Plasma image). Missing: the pointer.
    var touch: Bool?
    /// The image's login user (package-image.sh reads it from the build's manifest). Missing: a Henge image (checkGuest refuses it).
    var guestUser: String?

    var downloadBytes: Int64 { diskBytes + firmwareBytes }

    /// Free space an install takes: what is left to download, the decoded file, and 1 GB of margin.
    func spaceNeeded(alreadyDownloaded: Int64 = 0) -> Int64 {
        max(downloadBytes - alreadyDownloaded, 0) + unpackedBytes + (1 << 30)
    }

    /// Free space for the unpack alone: the decoded file and the disk both exist for a while.
    var unpackSpaceNeeded: Int64 { 2 * unpackedBytes + (1 << 30) }
}

enum LinuxCatalogue {
    static let urlKey = "tux.linux.catalogueURL"

    /// The catalogue URL typed in Settings, or nil.
    static var configuredURL: URL? {
        let text = (UserDefaults.standard.string(forKey: urlKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = URL(string: text), url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    private struct File: Decodable { var images: [LinuxImage] }

    /// File names in the catalogue may be relative: the packages sit next to linux-images.json.
    static func decode(_ data: Data, base: URL) throws -> [LinuxImage] {
        guard var list = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["images"] as? [[String: Any]] else {
            throw LinuxError.text("The catalogue has no list of images.")
        }
        for i in list.indices {
            for key in ["diskURL", "firmwareURL"] {
                if let s = list[i][key] as? String, let u = URL(string: s, relativeTo: base)?.absoluteURL { list[i][key] = u.absoluteString }
            }
        }
        do {
            let fixed = try JSONSerialization.data(withJSONObject: ["images": list])
            let images = try JSONDecoder().decode(File.self, from: fixed).images
            try images.forEach(validate)
            return images
        } catch let error as LinuxError {
            throw error
        } catch {
            throw LinuxError.text("The catalogue is not in the format Tuxedo expects (\(error.localizedDescription)).")
        }
    }

    /// 1 TiB keeps every size sum and shift far from overflow.
    static let maxBytes: Int64 = 1 << 40
    /// The Disk size stepper stops here (GiB), so a bigger image has no valid setting.
    static let maxDiskGB = 512

    /// id and version go into file names: no path separators, no "..".
    static func safeName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && !s.hasPrefix(".") && !s.contains("..")
            && s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-+".unicodeScalars.contains($0)) }
    }

    private static func validate(_ image: LinuxImage) throws {
        guard safeName(image.id) else { throw LinuxError.text("The catalogue has an image id that is not a plain name.") }
        guard safeName(image.version) else { throw LinuxError.text("\(image.name) has a version that is not a plain name.") }
        let sizes = [image.diskBytes, image.unpackedBytes, image.logicalBytes, image.firmwareBytes]
        guard sizes.allSatisfy({ $0 >= 0 && $0 <= maxBytes }) else { throw LinuxError.text("\(image.name) has a size that is out of range.") }
        guard image.logicalBytes <= Int64(maxDiskGB) << 30 else { throw LinuxError.text("\(image.name) needs a bigger disk than Tuxedo can make.") }
    }

    static func fetch(_ url: URL) async throws -> [LinuxImage] {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw LinuxError.text("Tuxedo could not reach the catalogue at \(url.absoluteString): \(error.localizedDescription)") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LinuxError.text("The catalogue server answered \(status).") }
        return try decode(data, base: url)
    }

    /// An entry that needs a newer Tuxedo is refused.
    static func checkBuild(_ image: LinuxImage, appBuild: Int) throws {
        if let min = image.minBuild, min > appBuild {
            throw LinuxError.text("\(image.name) needs a newer Tuxedo (build \(min); this is build \(appBuild)). Update Tuxedo to install it.")
        }
    }

    /// An entry with no guestUser is a Henge image: its guest tools use names this app does not serve.
    static func checkGuest(_ image: LinuxImage) throws {
        if (image.guestUser ?? "").isEmpty {
            throw LinuxError.text("\(image.name) is an image for Henge. Its Linux tools cannot talk to Tuxedo. Use a catalogue made for Tuxedo.")
        }
    }

    static var appBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }

    static func checkSpace(_ image: LinuxImage, free: Int64, alreadyDownloaded: Int64 = 0) throws {
        let needed = image.spaceNeeded(alreadyDownloaded: alreadyDownloaded)
        if free > 0 && free < needed {
            throw LinuxError.text("This install needs about \(sizeText(needed)) free; this device has \(sizeText(free)).")
        }
    }

    static func checkUnpackSpace(_ image: LinuxImage, free: Int64) throws {
        let needed = image.unpackSpaceNeeded
        if free > 0 && free < needed {
            throw LinuxError.text("Unpacking needs about \(sizeText(needed)) free; this device has \(sizeText(free)).")
        }
    }

    static func sizeText(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useGB, .useMB]
        return f.string(fromByteCount: bytes)
    }
}

struct LinuxError: LocalizedError {
    let message: String
    static func text(_ s: String) -> LinuxError { LinuxError(message: s) }
    var errorDescription: String? { message }
}

enum FileHash {
    /// SHA-256 of a file as lowercase hex, read in 4 MB pieces so a 300 MB image never sits in memory.
    static func sha256(of url: URL, progress: ((Int64) -> Void)? = nil) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        var done: Int64 = 0
        while true {
            let chunk = try h.read(upToCount: 4 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            done += Int64(chunk.count)
            progress?(done)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Deletes the file and throws when its hash is not the catalogue's.
    static func verify(_ url: URL, expected: String, what: String, progress: ((Int64) -> Void)? = nil) throws {
        let actual = try sha256(of: url, progress: progress)
        if actual != expected.lowercased() {
            try? FileManager.default.removeItem(at: url)
            throw LinuxError.text("The \(what) download was damaged (its checksum does not match). Tuxedo deleted it: try again.")
        }
    }
}
