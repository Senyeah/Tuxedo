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

    static func main() async throws {
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

        // id and version go into file names; sizes must not overflow or break the disk stepper.
        func entry(id: String = "x", version: String = "1", disk: String = "10", logical: String = "30") -> Data {
            Data("""
            {"images":[{"id":"\(id)","name":"N","version":"\(version)","kind":"console","diskURL":"d","diskBytes":\(disk),
             "diskSHA256":"00","unpackedBytes":20,"logicalBytes":\(logical),"firmwareURL":"f","firmwareBytes":5,"firmwareSHA256":"00"}]}
            """.utf8)
        }
        precondition(fails { _ = try LinuxCatalogue.decode(entry(), base: base) } == nil)
        for bad in ["../x", "a/b", "a\\\\b", "..", "a..b", ".hidden", "", "x y"] {
            precondition(fails { _ = try LinuxCatalogue.decode(entry(id: bad), base: base) } != nil, "id \(bad)")
            precondition(fails { _ = try LinuxCatalogue.decode(entry(version: bad), base: base) } != nil, "version \(bad)")
        }
        precondition(fails { _ = try LinuxCatalogue.decode(entry(disk: "9223372036854775807"), base: base) } != nil)
        precondition(fails { _ = try LinuxCatalogue.decode(entry(disk: "-1"), base: base) } != nil)
        precondition(fails { _ = try LinuxCatalogue.decode(entry(logical: "\(Int64(513) << 30)"), base: base) } != nil)
        precondition(fails { _ = try LinuxCatalogue.decode(entry(logical: "\(Int64(512) << 30)"), base: base) } == nil)

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

        // Shared firmware stays when another entry uses it; zero sizes never count as present.
        var b = a
        b.id = "other"
        try Data(count: 5).write(to: f.firmware)
        LinuxDownload.delete(a, in: dir, others: [a, b])
        precondition(fm.fileExists(atPath: f.firmware.path))
        LinuxDownload.delete(a, in: dir)
        precondition(!fm.fileExists(atPath: f.firmware.path))

        try await fetchTests(tmp)
        print("test_linux_catalogue: ok")
    }

    // A real fetch against a local server that answers Range, as tools/linux/serve.sh does.
    static func fetchTests(_ tmp: URL) async throws {
        let fm = FileManager.default
        let www = tmp.appendingPathComponent("www")
        try fm.createDirectory(at: www, withIntermediateDirectories: true)
        let disk = Data((0..<300_000).map { UInt8($0 % 251) })
        let fw = Data((0..<4_000).map { UInt8($0 % 97) })
        try disk.write(to: www.appendingPathComponent("d.bin"))
        try fw.write(to: www.appendingPathComponent("f.bin"))
        let py = """
        import http.server, re, os, sys
        class H(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *a): pass
            def do_GET(self):
                p = self.translate_path(self.path); d = open(p, 'rb').read()
                m = re.fullmatch(r'bytes=(\\d+)-', self.headers.get('Range', ''))
                if m:
                    s = int(m.group(1)); self.send_response(206)
                    self.send_header('Content-Range', 'bytes %d-%d/%d' % (s, len(d) - 1, len(d))); d = d[s:]
                else:
                    self.send_response(200)
                self.send_header('Content-Length', str(len(d))); self.end_headers(); self.wfile.write(d)
        os.chdir(sys.argv[1])
        s = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
        print(s.server_address[1], flush=True)
        s.serve_forever()
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", "-c", py, www.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        defer { proc.terminate() }
        let line = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(line) else { fatalError("no test server") }

        func image(diskSHA: String) -> LinuxImage {
            try! LinuxCatalogue.decode(Data("""
            {"images":[{"id":"t","name":"T","version":"1","kind":"console","diskURL":"d.bin","diskBytes":\(disk.count),
             "diskSHA256":"\(diskSHA)","unpackedBytes":1,"logicalBytes":1,"firmwareURL":"f.bin","firmwareBytes":\(fw.count),
             "firmwareSHA256":"\(sha(fw))","minBuild":1}]}
            """.utf8), base: URL(string: "http://127.0.0.1:\(port)/c.json")!)[0]
        }
        func sha(_ d: Data) -> String {
            let u = tmp.appendingPathComponent("h-\(UUID().uuidString)")
            try! d.write(to: u); defer { try? fm.removeItem(at: u) }
            return try! FileHash.sha256(of: u)
        }

        // Resume: a part of 100000 bytes is completed with a range request and verified.
        let dir = tmp.appendingPathComponent("fetch1")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let good = image(diskSHA: sha(disk))
        let gf = LinuxDownload.files(good, in: dir)
        try disk.prefix(100_000).write(to: gf.disk.appendingPathExtension("part"))
        _ = try await LinuxDownload.fetch(good, in: dir) { _, _, _ in }
        precondition(LinuxDownload.haveAll(good, in: dir))
        let got = try Data(contentsOf: gf.disk)
        precondition(got == disk)
        precondition(!fm.fileExists(atPath: gf.disk.appendingPathExtension("part").path))

        // A wrong hash deletes the file and says it was damaged.
        let dir2 = tmp.appendingPathComponent("fetch2")
        let bad = image(diskSHA: String(repeating: "0", count: 64))
        var msg = ""
        do { _ = try await LinuxDownload.fetch(bad, in: dir2) { _, _, _ in } } catch { msg = error.localizedDescription }
        precondition(msg.contains("damaged") && !LinuxDownload.haveAll(bad, in: dir2))
        precondition(!fm.fileExists(atPath: LinuxDownload.files(bad, in: dir2).disk.path))
    }
}
