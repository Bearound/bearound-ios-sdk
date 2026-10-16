import Foundation
import Testing
import zlib
@testable import BearoundSDK

@Suite("Request Body Encoding Tests")
struct RequestBodyEncodingTests {
    static func gunzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw RequestBodyEncoding.Failure.compression
        }
        defer { inflateEnd(&stream) }
        var output = Data(count: 524_289)
        let capacity = output.count
        let status = data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(capacity)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.avail_in == 0 else { throw RequestBodyEncoding.Failure.compression }
        output.count = Int(stream.total_out)
        return output
    }

    @Test("System zlib emits RFC1952 header trailer and exact UTF8 JSON")
    func interoperableGzip() throws {
        let json = try JSONSerialization.data(withJSONObject: ["text": String(repeating: "café / ☃", count: 500),
            "fraction": 12.75, "negative": -1, "absent": NSNull()])
        let encoded = try RequestBodyEncoding.encode(json, gzipAllowed: true)
        #expect(encoded.contentEncoding == "gzip" && encoded.contentType == "application/octet-stream")
        #expect(Array(encoded.data.prefix(3)) == [0x1f, 0x8b, 0x08])
        #expect(encoded.data.count < json.count && encoded.originalJsonBytes == json.count)
        #expect(try Self.gunzip(encoded.data) == json)
        let trailerSize = encoded.data.suffix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        #expect(trailerSize == UInt32(json.count))
        var corrupt = encoded.data
        corrupt[corrupt.count - 8] ^= 1
        #expect(throws: RequestBodyEncoding.Failure.self) { try Self.gunzip(corrupt) }
    }

    @Test("Identity preserves all original bytes and has no content encoding")
    func identity() throws {
        let json = Data("{\"value\":\"café / ☃\"}".utf8)
        let encoded = try RequestBodyEncoding.encode(json, gzipAllowed: false)
        #expect(encoded.data == json && encoded.contentEncoding == nil && encoded.contentType == "application/json")
    }

    @Test("Non beneficial gzip and compressor failure retain identity")
    func optionalCompression() throws {
        let json = Data("{}".utf8)
        #expect(try RequestBodyEncoding.encode(json, gzipAllowed: true).contentEncoding == nil)
        let failure = try RequestBodyEncoding.encode(json, gzipAllowed: true) { _ in throw RequestBodyEncoding.Failure.compression }
        let larger = try RequestBodyEncoding.encode(json, gzipAllowed: true) { $0 + Data([0]) }
        let same = try RequestBodyEncoding.encode(json, gzipAllowed: true) { $0 }
        let empty = try RequestBodyEncoding.encode(json, gzipAllowed: true) { _ in Data() }
        for encoded in [failure, larger, same, empty] { #expect(encoded.data == json && encoded.contentEncoding == nil) }
    }

    @Test("Original JSON budget is enforced before any compression")
    func originalBudget() throws {
        var calls = 0
        for size in [0, 524_289] {
            #expect(throws: RequestBodyEncoding.Failure.self) {
                try RequestBodyEncoding.encode(Data(repeating: 65, count: size), gzipAllowed: true) { _ in calls += 1; return Data([1]) }
            }
        }
        #expect(throws: RequestBodyEncoding.Failure.self) {
            try RequestBodyEncoding.encode(Data(repeating: 65, count: 101), gzipAllowed: true, maximumJSONBytes: 100) { _ in
                calls += 1; return Data([1])
            }
        }
        #expect(calls == 0)
        #expect(try RequestBodyEncoding.encode(Data(repeating: 65, count: 524_288), gzipAllowed: true).contentEncoding == "gzip")
    }
}
