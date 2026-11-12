import Foundation

@main
struct LinuxCatalogueTests {
    // The shape tools/linux/package-image.sh writes (G7), with one entry that needs a newer Henge.
    static let sample = """
    {"images":[
     {"id":"debian-console","name":"Debian 13 (console)","version":"20261112","kind":"console",
      "diskURL":"debian-console-20261112.hvsparse.lzfse","diskBytes":192528501,
      "diskSHA256":"64d4689dc5bb6891713553686c2786d7a056ec926e10585089a0c31878c64693",
      "unpackedBytes":473957360,"logicalBytes":3221225472,
      "firmwareURL":"u-boot-860450f43d3b.bin","firmwareBytes":1507200,
      "firmwareSHA256":"860450f43d3b32ba5f24554b8cf128ad6ad23a3eab84c3b28e5feab52e00889e",
      "kernel":"6.12.107+deb13-arm64-16k","minBuild":102},
     {"id":"future","name":"Future","version":"1","kind":"console","diskURL":"https://cdn.example.com/f.lzfse","diskBytes":10,
      "diskSHA256":"00","unpackedBytes":20,"logicalBytes":30,"firmwareURL":"https://cdn.example.com/u.bin","firmwareBytes":5,
      "firmwareSHA256":"00","minBuild":9999}]}
    """

    static func fails(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch { return error.localizedDescription }
    }

    static func main() throws {
        let base = URL(string: "http://192.168.1.5:8000/linux-images.json")!
        let images = try LinuxCatalogue.decode(Data(sample.utf8), base: base)
        precondition(images.count == 2)
        let a = images[0]
        precondition(a.id == "debian-console" && a.version == "20261112" && a.diskBytes == 192528501 && a.minBuild == 102)
        precondition(a.diskURL.absoluteString == "http://192.168.1.5:8000/debian-console-20261112.hvsparse.lzfse")
        precondition(a.firmwareURL.absoluteString == "http://192.168.1.5:8000/u-boot-860450f43d3b.bin")
        precondition(images[1].diskURL.absoluteString == "https://cdn.example.com/f.lzfse") // absolute URLs stay
        precondition(fails { _ = try LinuxCatalogue.decode(Data("{\"nope\":1}".utf8), base: base) } != nil)
        precondition(fails { _ = try LinuxCatalogue.decode(Data("{\"images\":[{\"id\":\"x\"}]}".utf8), base: base) } != nil)

        // Space: what is left to download, plus the decoded file, plus 1 GB.
        let gb: Int64 = 1 << 30
        precondition(a.spaceNeeded() == 192528501 + 1507200 + 473957360 + gb)
        precondition(a.spaceNeeded(alreadyDownloaded: 100_000_000) == 192528501 + 1507200 - 100_000_000 + 473957360 + gb)
        precondition(a.spaceNeeded(alreadyDownloaded: 1 << 40) == 473957360 + gb)
        precondition(fails { try LinuxCatalogue.checkSpace(a, free: gb) }?.contains("free") == true)
        precondition(fails { try LinuxCatalogue.checkSpace(a, free: a.spaceNeeded()) } == nil)
        precondition(fails { try LinuxCatalogue.checkSpace(a, free: 0) } == nil) // unknown free space does not block

        // minBuild: an entry above the app's build is refused with a message that says to update.
        precondition(fails { try LinuxCatalogue.checkBuild(a, appBuild: 102) } == nil)
        let tooNew = fails { try LinuxCatalogue.checkBuild(a, appBuild: 101) }
        precondition(tooNew?.contains("Update Henge") == true)
        precondition(fails { try LinuxCatalogue.checkBuild(images[1], appBuild: 102) } != nil)

        // Hashes: right one passes, wrong one deletes the file and says it was damaged.
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("linux-catalogue-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("blob")
        try Data("henge".utf8).write(to: file)
        let hello = try FileHash.sha256(of: file)
        precondition(hello == "90961d66d0be50ec2ba9eb0bc994120ebd6e0d61052185c53bdf9107778436bd")
        precondition(fails { try FileHash.verify(file, expected: hello.uppercased(), what: "disk") } == nil && fm.fileExists(atPath: file.path))
        let bad = fails { try FileHash.verify(file, expected: String(repeating: "0", count: 64), what: "disk") }
        precondition(bad?.contains("damaged") == true && !fm.fileExists(atPath: file.path))

        // A file bigger than the 4 MB read size hashes in several pieces.
        let big = tmp.appendingPathComponent("big")
        try Data(repeating: 0x61, count: (9 << 20) + 17).write(to: big)
        var last: Int64 = 0
        let bigHash = try FileHash.sha256(of: big) { last = $0 }
        precondition(bigHash.count == 64 && last == Int64((9 << 20) + 17))

        // Download bookkeeping: names, present bytes, whole-file check.
        let dir = LinuxDownload.folder(root: tmp)
        precondition(dir.lastPathComponent == "Linux images")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = LinuxDownload.files(a, in: dir)
        precondition(f.disk.lastPathComponent == "debian-console-20261112.hvsparse.lzfse" && f.firmware.lastPathComponent == "u-boot-860450f43d3b.bin")
        precondition(!LinuxDownload.haveAll(a, in: dir) && LinuxDownload.present(a, in: dir) == 0)
        try Data(count: 1000).write(to: f.disk.appendingPathExtension("part"))
        precondition(LinuxDownload.present(a, in: dir) == 1000)
        LinuxDownload.delete(a, in: dir)
        precondition(LinuxDownload.present(a, in: dir) == 0)

        print("test_linux_catalogue: ok")
    }
}
