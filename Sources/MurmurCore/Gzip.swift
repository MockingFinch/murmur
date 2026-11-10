import Foundation
import zlib

/// gzip in and out, through the system's zlib.
public enum Gzip {
    public enum Failure: Error { case init_(Int32), stream(Int32), tooLarge }

    /// Compresses `data` into a gzip member (RFC 1952).
    public static func compress(_ data: Data) throws -> Data {
        var stream = z_stream()
        // windowBits 15 + 16 asks zlib for a gzip header and trailer.
        var status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8,
                                   Z_DEFAULT_STRATEGY, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw Failure.init_(status) }
        defer { deflateEnd(&stream) }

        var input = data
        var output = Data()
        let chunk = 16 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        input.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            stream.next_in = raw.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(raw.count)
            repeat {
                buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(chunk)
                    status = deflate(&stream, Z_FINISH)
                    output.append(out.baseAddress!, count: chunk - Int(stream.avail_out))
                }
            } while status == Z_OK
        }
        guard status == Z_STREAM_END else { throw Failure.stream(status) }
        return output
    }

    /// Inflates gzip (or zlib) data, refusing anything that would grow past `limit` bytes.
    public static func decompress(_ data: Data, limit: Int = 8 << 20) throws -> Data {
        if data.isEmpty { return Data() }
        var stream = z_stream()
        // windowBits 15 + 32: detect gzip or zlib headers automatically.
        var status = inflateInit2_(&stream, 15 + 32, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw Failure.init_(status) }
        defer { inflateEnd(&stream) }

        var input = data
        var output = Data()
        let chunk = 32 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        var tooLarge = false
        input.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            stream.next_in = raw.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(raw.count)
            repeat {
                buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(chunk)
                    status = inflate(&stream, Z_NO_FLUSH)
                    output.append(out.baseAddress!, count: chunk - Int(stream.avail_out))
                }
                if output.count > limit { tooLarge = true; break }
            } while status == Z_OK
        }
        if tooLarge { throw Failure.tooLarge }
        guard status == Z_STREAM_END else { throw Failure.stream(status) }
        return output
    }
}
