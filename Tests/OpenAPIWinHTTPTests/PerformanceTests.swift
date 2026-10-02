// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

private import class Foundation.ProcessInfo
private import struct FoundationEssentials.URL
internal import HTTPTypes
internal import OpenAPIRuntime
internal import Testing
internal import OpenAPIWinHTTPTransport

private let kBenchmark =
    ProcessInfo.processInfo.environment["WINHTTP_BENCHMARK"]

/// Opt-in, sequential Release measurements. The fixture and workload are shared
/// by all revisions; no timing thresholds are imposed on CI.
internal struct PerformanceTests {
  @Test(.enabled(if: kBenchmark != nil))
  internal func measure() async throws(any Error) {
    let mode = kBenchmark ?? "all"
    let clock = ContinuousClock()
    func nanoseconds(_ duration: Duration) -> Double {
      let parts = duration.components
      let seconds = Double(parts.seconds) * 1_000_000_000
      let fraction = Double(parts.attoseconds) / 1_000_000_000
      return seconds + fraction
    }
    func report(_ name: String, iterations: Int, samples: Array<Double>,
                checksum: Int) {
      let values = samples.map { String($0) }.joined(separator: ",")
      print("BENCH {\"name\":\"\(name)\",\"iterations\":\(iterations)," +
            "\"ns_per_op\":[\(values)],\"checksum\":\(checksum)}")
    }

    if mode != "uploads" {
      let workloads = [("request-small", 6, 32, false),
                       ("request-many", 24, 128, false),
                       ("request-latin1", 24, 128, true),]
      for (name, count, size, latin) in workloads {
        var fields = HTTPFields()
        for index in 0 ..< count {
          let name = try #require(HTTPField.Name("X-Bench-\(index)"))
          let bytes = (0 ..< size).map {
            latin ? UInt8(0xa0 + $0 % 96) : UInt8(ascii: "x")
          }
          fields.append(HTTPField(name: name, value: bytes))
        }
        var samples = Array<Double>()
        var checksum = 0
        let iterations = 10000
        for sample in 0 ..< 8 {
          let start = clock.now
          for _ in 0 ..< iterations {
            let upload = try UploadRequest(fields: fields, length: .known(0))
            checksum &+= upload.headers.withUnsafeBufferPointer {
              Int($0[0]) + Int($0[12])
            }
          }
          let duration = nanoseconds(start.duration(to: clock.now))
          let elapsed = duration / Double(iterations)
          if sample > 0 { samples.append(elapsed) }
        }
        report(name, iterations: iterations, samples: samples,
               checksum: checksum)
      }

      let environment = ProcessInfo.processInfo.environment
      let address = try #require(environment["WINHTTP_TEST_URL"])
      let url = try #require(URL(string: address))
      for name in ["small", "many", "large"] {
        let request = HTTPRequest(method: .get, scheme: nil, authority: nil,
                                  path: "/benchmark/\(name)")
        let target = try WinHttpTarget(request: request, url: url)
        let upload =
            try UploadRequest(fields: request.headerFields, length: nil)
        let context = try RequestContext(method: request.method, target: target,
                                         streaming: false)
        defer { context.finish() }
        try await context.send(upload.headers, total: upload.total)
        try await context.receive()
        var samples = Array<Double>()
        var checksum = 0
        let iterations = 3000
        for sample in 0 ..< 8 {
          let start = clock.now
          for _ in 0 ..< iterations {
            let response = try context.response()
            checksum &+= response.headerFields.count
          }
          let duration = nanoseconds(start.duration(to: clock.now))
          let elapsed = duration / Double(iterations)
          if sample > 0 { samples.append(elapsed) }
        }
        report("response-\(name)", iterations: iterations, samples: samples,
               checksum: checksum)
      }
    }

    if mode != "headers" {
      let environment = ProcessInfo.processInfo.environment
      let address = try #require(environment["WINHTTP_TEST_URL"])
      let url = try #require(URL(string: address))
      let bytes = Array(repeating: UInt8(ascii: "x"), count: 1024 * 1024)
      for known in [true, false] {
        for size in [1024, 65536] {
          var samples = Array<Double>()
          var checksum = 0
          let iterations = 8
          for sample in 0 ..< 6 {
            let start = clock.now
            for _ in 0 ..< iterations {
              let stream = AsyncStream<ArraySlice<UInt8>> { continuation in
                for offset in stride(from: 0, to: bytes.count, by: size) {
                  let end = min(offset + size, bytes.count)
                  continuation.yield(bytes[offset ..< end])
                }
                continuation.finish()
              }
              let length: HTTPBody.Length =
                  known ? .known(Int64(bytes.count)) : .unknown
              let body = HTTPBody(stream, length: length,
                                  iterationBehavior: .single)
              let request =
                  HTTPRequest(method: .post, scheme: nil, authority: nil,
                              path: "/benchmark-upload")
              let (response, result) =
                  try await WinHttpTransport().send(request, body: body,
                                                    baseURL: url,
                                                    operationID: "benchmark")
              #expect(response.status == .ok)
              let name = try #require(HTTPField.Name("X-Upload-Length"))
              #expect(response.headerFields[name] == String(bytes.count))
              if let result {
                for try await chunk in result { checksum &+= chunk.count }
              }
              checksum &+= Int(response.status.code)
            }
            let duration = nanoseconds(start.duration(to: clock.now))
            let elapsed = duration / Double(iterations)
            if sample > 0 { samples.append(elapsed) }
          }
          report("upload-\(known ? "known" : "unknown")-\(size)",
                 iterations: iterations, samples: samples, checksum: checksum)
        }
      }
    }
  }
}
