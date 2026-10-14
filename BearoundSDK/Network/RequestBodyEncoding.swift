import Foundation
import zlib

struct EncodedRequestBody {
    let data: Data
    let contentType: String
    let contentEncoding: String?
    let originalJsonBytes: Int
}

struct RequestEncodingLease: Equatable {
    let bootIdentifier: String
    let expiresAtMonotonicMs: Int64
}

enum RequestBodyEncoding {
    enum Failure: Error { case invalidBudget, compression }

    static func encode(_ json: Data, gzipAllowed: Bool, maximumJSONBytes: Int = 524_288,
                       compressor: (Data) throws -> Data = gzip) throws -> EncodedRequestBody {
        guard !json.isEmpty, json.count <= min(524_288, maximumJSONBytes) else { throw Failure.invalidBudget }
        if gzipAllowed, let compressed = try? compressor(json), !compressed.isEmpty, compressed.count < json.count {
            return EncodedRequestBody(data: compressed, contentType: "application/octet-stream",
                contentEncoding: "gzip", originalJsonBytes: json.count)
        }
        return EncodedRequestBody(data: json, contentType: "application/json", contentEncoding: nil,
            originalJsonBytes: json.count)
    }

    static func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                           zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.compression }
        defer { deflateEnd(&stream) }
        let capacity = Int(deflateBound(&stream, uLong(data.count)))
        var output = Data(count: capacity)
        let result = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { target in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(capacity)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END, stream.avail_in == 0 else { throw Failure.compression }
        output.count = Int(stream.total_out)
        return output
    }
}
