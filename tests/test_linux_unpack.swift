import Foundation

@main
struct LinuxUnpackTests {
    static let fm = FileManager.default

    static func fails(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch { return error.localizedDescription }
    }

    static func run(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try! p.run()
        p.waitUntilExit()
        precondition(p.terminationStatus == 0, "\(tool) failed")
    }

    static func check(_ ok: @autoclosure () throws -> Bool, line: UInt = #line) rethrows { if !(try ok()) { fatalError("check failed", line: line) } }

    static func size(_ url: URL) throws -> Int64 { (try fm.attributesOfItem(atPath: url.path)[.size] as! NSNumber).int64Value }

    static func main() throws {
        let tmp = fm.temporaryDirectory.appendingPathComponent("test_linux_unpack-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // A 40 MB sparse disk: random data (more than one 1 MB read and 4 MB write), a hole, data near the end.
        let disk = tmp.appendingPathComponent("disk.img")
        let logical = 40 << 20
        var head = Data(count: 6 << 20)
        head.withUnsafeMutableBytes { p in for i in 0..<p.count { p[i] = UInt8.random(in: 0...255) } }
        var tail = Data(count: 100_000)
        tail.withUnsafeMutableBytes { p in for i in 0..<p.count { p[i] = UInt8(truncatingIfNeeded: i &* 7 &+ 3) } }
        fm.createFile(atPath: disk.path, contents: nil)
        let h = try FileHandle(forWritingTo: disk)
        try h.truncate(atOffset: UInt64(logical))
        try h.seek(toOffset: 1 << 20); try h.write(contentsOf: head)
        try h.seek(toOffset: UInt64(logical - 200_000)); try h.write(contentsOf: tail)
        try h.close()

        let packed = tmp.appendingPathComponent("disk.hvsparse")
        precondition(hv_sparse_pack(disk.path, packed.path) == 0)
        let lzfse = tmp.appendingPathComponent("disk.hvsparse.lzfse")
        run("/usr/bin/compression_tool", ["-encode", "-a", "lzfse", "-i", packed.path, "-o", lzfse.path])
        let unpackedBytes = try size(packed)
        let fw = tmp.appendingPathComponent("u-boot-x.bin")
        try Data("firmware".utf8).write(to: fw)
        let files = LinuxDownload.Files(disk: lzfse, firmware: fw)

        func image(unpacked: Int64 = unpackedBytes) -> LinuxImage {
            LinuxImage(id: "t", name: "Test Linux", version: "1", kind: "console", diskURL: URL(string: "http://x/d")!, diskBytes: 1,
                       diskSHA256: "", unpackedBytes: unpacked, logicalBytes: Int64(logical), firmwareURL: URL(string: "http://x/f")!,
                       firmwareBytes: 8, firmwareSHA256: "")
        }
        func machine(_ img: LinuxImage, disk: Int64) -> VirtualMachine {
            var m = VirtualMachine(name: "Dev \"quoted\"", ramMB: 1536, diskBytes: disk)
            m.osName = img.name
            m.guestUser = "tux"
            return m
        }

        // The decode alone matches what the packer wrote.
        let decoded = tmp.appendingPathComponent("decoded")
        var steps = 0
        let n = try LinuxUnpack.decode(lzfse, to: decoded) { _, _ in steps += 1 }
        precondition(n == unpackedBytes && steps > 1)
        try check(Data(contentsOf: decoded) == Data(contentsOf: packed))

        // A machine at a size above the image's: the data is the same, the disk is longer, the folder is whole.
        let img = image()
        let want = Int64(logical) + (24 << 20)
        let dir = tmp.appendingPathComponent("machine")
        var stages = Set<String>()
        try LinuxUnpack.make(img, files: files, into: dir, machine: machine(img, disk: want), diskBytes: want) { s, _, _ in stages.insert("\(s)") }
        precondition(stages == ["decode", "unpack"])
        let made = dir.appendingPathComponent("disk.img")
        try check(size(made) == want)
        let a = try FileHandle(forReadingFrom: disk), b = try FileHandle(forReadingFrom: made)
        for _ in 0..<(logical >> 20) {
            try check(a.read(upToCount: 1 << 20) == b.read(upToCount: 1 << 20))
        }
        try check(b.read(upToCount: 1 << 20)?.allSatisfy { $0 == 0 } ?? true) // the new part is empty
        try check(Data(contentsOf: dir.appendingPathComponent("u-boot.bin")) == Data("firmware".utf8))
        precondition(!fm.fileExists(atPath: dir.appendingPathComponent("disk.img.hvsparse").path))
        let info = MachineFolder.info(dir)
        precondition(info?.ramMB == 1536 && info?.name == "Dev \"quoted\"" && info?.guestUser == "tux") // a quote must not break the file
        try check(String(contentsOf: dir.appendingPathComponent("installed"), encoding: .utf8) == "Test Linux")
        precondition(!fm.fileExists(atPath: dir.appendingPathComponent("installing").path)) // the installing marker goes when the folder is complete
        let recovered = MachineList.recover(id: UUID(), folder: dir, defaultRAMMB: 2048)
        precondition(recovered?.diskBytes == want && recovered?.osName == "Test Linux" && recovered?.user == "tux")

        // The image's own size: no growing.
        let dir2 = tmp.appendingPathComponent("machine2")
        try LinuxUnpack.make(img, files: files, into: dir2, machine: machine(img, disk: Int64(logical)), diskBytes: Int64(logical)) { _, _, _ in }
        try check(size(dir2.appendingPathComponent("disk.img")) == Int64(logical))

        // Below the image's size: refused, and nothing is left.
        let dir3 = tmp.appendingPathComponent("machine3")
        let small = fails { try LinuxUnpack.make(img, files: files, into: dir3, machine: machine(img, disk: 1 << 20), diskBytes: 1 << 20) { _, _, _ in } }
        precondition(small?.contains("at least") == true && !fm.fileExists(atPath: dir3.path))

        // A download cut short, and a wrong decoded size: each fails and removes the folder.
        let cut = tmp.appendingPathComponent("cut.lzfse")
        try Data(contentsOf: lzfse).prefix(Int(try size(lzfse)) / 2).write(to: cut)
        let dir4 = tmp.appendingPathComponent("machine4")
        let bad = fails { try LinuxUnpack.make(img, files: .init(disk: cut, firmware: fw), into: dir4, machine: machine(img, disk: want), diskBytes: want) { _, _, _ in } }
        precondition(bad != nil && !fm.fileExists(atPath: dir4.path))
        let dir5 = tmp.appendingPathComponent("machine5")
        let wrong = image(unpacked: unpackedBytes + 1)
        let wrongSize = fails { try LinuxUnpack.make(wrong, files: files, into: dir5, machine: machine(wrong, disk: want), diskBytes: want) { _, _, _ in } }
        precondition(wrongSize?.contains("wrong size") == true && !fm.fileExists(atPath: dir5.path))

        // Not an LZFSE file at all.
        let junk = tmp.appendingPathComponent("junk.lzfse")
        try Data(repeating: 0x41, count: 5000).write(to: junk)
        precondition(fails { _ = try LinuxUnpack.decode(junk, to: tmp.appendingPathComponent("junk.out")) } != nil)

        // Sizes: 16 GB by default, never under the image; the unpack space is twice the decoded file plus 1 GB.
        let gb: Int64 = 1 << 30
        let big = LinuxImage(id: "b", name: "B", version: "1", kind: "console", diskURL: URL(string: "http://x/d")!, diskBytes: 1, diskSHA256: "",
                             unpackedBytes: 473_957_360, logicalBytes: 3 * gb, firmwareURL: URL(string: "http://x/f")!, firmwareBytes: 1, firmwareSHA256: "")
        precondition(LinuxUnpack.diskBytes(chosen: nil, for: big) == 16 * gb)
        precondition(LinuxUnpack.diskBytes(chosen: 8 * gb, for: big) == 8 * gb)
        precondition(LinuxUnpack.diskBytes(chosen: gb, for: big) == 3 * gb)
        precondition(LinuxUnpack.minDiskGB(for: big) == 3 && LinuxUnpack.defaultDiskGB(for: big) == 16)
        var odd = big
        odd.logicalBytes = 3 * gb + 1
        precondition(LinuxUnpack.minDiskGB(for: odd) == 4)
        precondition(big.unpackSpaceNeeded == 2 * 473_957_360 + gb)
        precondition(fails { try LinuxCatalogue.checkUnpackSpace(big, free: gb) }?.contains("Unpacking needs") == true)
        precondition(fails { try LinuxCatalogue.checkUnpackSpace(big, free: 100 * gb) } == nil)
        precondition(fails { try LinuxCatalogue.checkUnpackSpace(big, free: 0) } == nil) // unknown free space does not block

        print("linux unpack: all checks passed")
    }
}
