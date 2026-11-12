import Compression
import Foundation

/// Decodes the downloaded LZFSE file, unpacks the sparse disk and writes a Linux machine's folder.
/// No UI and no engine: the new machine starts later, like any other.
enum LinuxUnpack {
    enum Stage { case decode, unpack }

    static let defaultDiskBytes: Int64 = 16 << 30

    /// The disk size to make: the default 16 GB, but never below what the image already holds.
    static func diskBytes(chosen: Int64?, for image: LinuxImage) -> Int64 {
        max(chosen ?? defaultDiskBytes, image.logicalBytes)
    }

    /// Whole GB (GiB, as the guest's df shows them) the disk setting cannot go below.
    static func minDiskGB(for image: LinuxImage) -> Int { Int((image.logicalBytes + (1 << 30) - 1) >> 30) }

    static func defaultDiskGB(for image: LinuxImage) -> Int { Int(diskBytes(chosen: nil, for: image) >> 30) }

    static func checkDisk(_ bytes: Int64, for image: LinuxImage) throws {
        if bytes < image.logicalBytes {
            throw LinuxError.text("The disk must be at least \(LinuxCatalogue.sizeText(image.logicalBytes)) for this image.")
        }
    }

    /// Streams `src` through LZFSE into `dst`, so the decoded file is never in memory. Returns the decoded size.
    static func decode(_ src: URL, to dst: URL, progress: (Int64, Int64) -> Void = { _, _ in }) throws -> Int64 {
        let inFD = open(src.path, O_RDONLY)
        guard inFD >= 0 else { throw LinuxError.text("The downloaded disk could not be opened.") }
        defer { close(inFD) }
        let outFD = open(dst.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard outFD >= 0 else { throw LinuxError.text("The disk could not be written (not enough space?).") }
        var outClosed = false
        defer { if !outClosed { close(outFD) } }

        var total: Int64 = 0
        var st = stat()
        if fstat(inFD, &st) == 0 { total = Int64(st.st_size) }

        let inSize = 1 << 20, outSize = 4 << 20
        let inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: inSize)
        let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: outSize)
        defer { inBuf.deallocate(); outBuf.deallocate() }

        // dst_ptr and src_ptr are set before the first process call; the init values are replaced
        let dummy = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { dummy.deallocate() }
        var stream = compression_stream(dst_ptr: dummy, dst_size: 0, src_ptr: UnsafePointer(dummy), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else {
            throw LinuxError.text("The disk could not be decoded.")
        }
        defer { compression_stream_destroy(&stream) }

        stream.src_ptr = UnsafePointer(inBuf)
        stream.src_size = 0
        stream.dst_ptr = outBuf
        stream.dst_size = outSize
        var read: Int64 = 0, written: Int64 = 0
        var atEnd = false
        var ended = false

        while !ended {
            if Task.isCancelled { throw CancellationError() }
            if stream.src_size == 0 && !atEnd {
                let n = Foundation.read(inFD, inBuf, inSize)
                if n < 0 { throw LinuxError.text("The downloaded disk could not be read.") }
                if n == 0 { atEnd = true }
                stream.src_ptr = UnsafePointer(inBuf)
                stream.src_size = n
                read += Int64(n)
            }
            let status = compression_stream_process(&stream, atEnd ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
            switch status {
            case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                let have = outSize - stream.dst_size
                if have > 0 {
                    try writeAll(outFD, outBuf, have)
                    written += Int64(have)
                    stream.dst_ptr = outBuf
                    stream.dst_size = outSize
                }
                if status == COMPRESSION_STATUS_END { ended = true }
                progress(read, total)
            default:
                throw LinuxError.text("The downloaded disk is not a valid compressed image.")
            }
        }
        guard fsync(outFD) == 0, close(outFD) == 0 else { outClosed = true; throw LinuxError.text("The disk could not be written (not enough space?).") }
        outClosed = true
        progress(total, total)
        return written
    }

    private static func writeAll(_ fd: Int32, _ p: UnsafeMutablePointer<UInt8>, _ n: Int) throws {
        var off = 0
        while off < n {
            let w = write(fd, p + off, n - off)
            if w <= 0 { throw LinuxError.text("The disk could not be written (not enough space?).") }
            off += w
        }
    }

    /// Passes a Swift closure through the C progress callback.
    private final class Box { let call: (Int64, Int64) -> Void; init(_ c: @escaping (Int64, Int64) -> Void) { call = c } }

    static func sparseUnpack(_ src: URL, to dst: URL, progress: @escaping (Int64, Int64) -> Void) throws {
        let box = Box(progress)
        let rc = hv_sparse_unpack(src.path, dst.path, { done, total, opaque in
            Unmanaged<Box>.fromOpaque(opaque!).takeUnretainedValue().call(Int64(done), Int64(total))
        }, Unmanaged.passUnretained(box).toOpaque())
        withExtendedLifetime(box) {}
        guard rc == 0 else { throw LinuxError.text("The disk could not be unpacked (not enough space?).") }
    }

    /// Makes the machine's folder: disk.img at the chosen size, u-boot.bin, machine.json, then the installed marker.
    /// A failure removes the folder. Blocks for as long as the unpack takes: call it off the main thread.
    static func make(_ image: LinuxImage, files: LinuxDownload.Files, into dir: URL, mac: VirtualMac, diskBytes: Int64,
                     progress: @escaping (Stage, Int64, Int64) -> Void) throws {
        let fm = FileManager.default
        do {
            try checkDisk(diskBytes, for: image)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let packed = dir.appendingPathComponent("disk.img.hvsparse")
            let disk = dir.appendingPathComponent("disk.img")
            let decoded = try decode(files.disk, to: packed) { progress(.decode, $0, $1) }
            if image.unpackedBytes > 0 && decoded != image.unpackedBytes {
                throw LinuxError.text("The disk decoded to the wrong size. Delete the download and try again.")
            }
            try sparseUnpack(packed, to: disk) { progress(.unpack, $0, $1) }
            try? fm.removeItem(at: packed)
            let now = (try fm.attributesOfItem(atPath: disk.path)[.size] as? Int64) ?? 0
            if diskBytes > now { try DiskGrowth.grow(disk, toBytes: diskBytes) }
            try fm.copyItem(at: files.firmware, to: dir.appendingPathComponent("u-boot.bin"))
            try JSONSerialization.data(withJSONObject: MachineFolder.exportInfo(mac)).write(to: dir.appendingPathComponent("machine.json"))
            // Last: the list is rebuilt from folders with this marker after a crash
            try (mac.osName ?? "").write(to: dir.appendingPathComponent(MachinePaths.installedMarker), atomically: true, encoding: .utf8)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }
}
