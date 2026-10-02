// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

private import class Foundation.ProcessInfo
private import struct FoundationEssentials.Data
private import class FoundationEssentials.JSONDecoder
private import struct FoundationEssentials.URL
private import struct FoundationEssentials.UUID
internal import HTTPTypes
internal import OpenAPIRuntime
internal import Testing
internal import OpenAPIWinHTTPTransport

private let kFixture = ProcessInfo.processInfo.environment["WINHTTP_TEST_URL"]
private let kTLS = ProcessInfo.processInfo.environment["WINHTTP_TEST_TLS_URL"]
private let kTrusted =
    ProcessInfo.processInfo.environment["WINHTTP_TEST_TRUSTED_URL"]
private let kProtocols =
    ProcessInfo.processInfo.environment["WINHTTP_TEST_PROTOCOL_URL"]
private let kHTTP2 =
    ProcessInfo.processInfo.environment["WINHTTP_TEST_HTTP2_URL"]

@Suite(.serialized, .enabled(if: kFixture != nil))
internal struct IntegrationTests {
  private struct Greeting: Decodable {
    internal let message: String
  }

  private struct Echo: Decodable {
    internal let data: String
  }

  private func send(_ transport: WinHttpTransport, path: String,
                    method: HTTPRequest.Method = .get,
                    body: HTTPBody? = nil) async throws
      -> (HTTPResponse, HTTPBody?) {
    let fixture = try #require(kFixture)
    let url = try #require(URL(string: fixture))
    let request =
        HTTPRequest(method: method, scheme: nil, authority: nil, path: path)
    return try await transport.send(request, body: body, baseURL: url,
                                    operationID: "test")
  }

  private func collect(_ body: HTTPBody?) async throws -> Array<UInt8> {
    var bytes = Array<UInt8>()
    for try await chunk in try #require(body) {
      bytes.append(contentsOf: chunk)
    }
    return bytes
  }

  @Test("HTTPS rejects untrusted certificates", .enabled(if: kTLS != nil))
  internal func untrusted() async throws {
    let address = try #require(kTLS)
    let url = try #require(URL(string: address))
    let request =
        HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/")
    await #expect(throws: OpenAPIWinHTTPError.windows(code: 12175)) {
      try await WinHttpTransport().send(request, body: nil, baseURL: url,
                                        operationID: "tls")
    }
  }

  @Test("HTTPS accepts a trusted server", .enabled(if: kTrusted != nil))
  internal func trusted() async throws {
    let address = try #require(kTrusted)
    let url = try #require(URL(string: address))
    let request =
        HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/")
    let (response, body) =
        try await WinHttpTransport().send(request, body: nil, baseURL: url,
                                          operationID: "tls")
    #expect(response.status == .ok)
    #expect(try await collect(body).isEmpty == false)
  }

  @Test("Known and unknown uploads preserve bytes", arguments: [true, false])
  internal func upload(known: Bool) async throws {
    let bytes = (0 ..< 196611).map { UInt8(truncatingIfNeeded: $0) }
    let stream = AsyncStream<ArraySlice<UInt8>> { continuation in
      continuation.yield(bytes[..<97])
      continuation.yield(bytes[97 ..< 97])
      continuation.yield(bytes[97...])
      continuation.finish()
    }
    let length: HTTPBody.Length = known ? .known(Int64(bytes.count)) : .unknown
    let body = HTTPBody(stream, length: length, iterationBehavior: .single)
    let (response, result) = try await send(WinHttpTransport(), path: "/echo",
                                            method: .post, body: body)
    #expect(response.status == .ok)
    #expect(try await collect(result) == bytes)
    let name = try #require(HTTPField.Name("X-Method"))
    #expect(response.headerFields[name] == "POST")
  }

  @Test("Empty streaming uploads terminate")
  internal func termination() async throws {
    let stream = AsyncStream<ArraySlice<UInt8>> { $0.finish() }
    let body = HTTPBody(stream, length: .unknown, iterationBehavior: .single)
    let (response, result) =
        try await send(WinHttpTransport(), path: "/echo", method: .post,
                       body: body)
    #expect(response.status == .ok)
    #expect(try await collect(result).isEmpty)
  }

  @Test("Explicit chunked uploads preserve slice bytes")
  internal func framing() async throws {
    let fixture = try #require(kFixture)
    let url = try #require(URL(string: fixture))
    let bytes = (0 ..< 65539).map { UInt8(truncatingIfNeeded: $0) }
    let slice = bytes[3...]
    let stream = AsyncStream<ArraySlice<UInt8>> { continuation in
      continuation.yield(slice)
      continuation.finish()
    }
    let body = HTTPBody(stream, length: .known(Int64(slice.count)),
                        iterationBehavior: .single)
    let request = HTTPRequest(method: .post, scheme: nil, authority: nil,
                              path: "/echo",
                              headerFields: [.transferEncoding: "chunked"])
    let (response, result) =
        try await WinHttpTransport().send(request, body: body, baseURL: url,
                                          operationID: "framing")
    #expect(response.status == .ok)
    #expect(try await collect(result) == Array(slice))
  }

  @Test("HTTPS negotiates HTTP/3", .enabled(if: kProtocols != nil))
  internal func protocols() async throws {
    let address = try #require(kProtocols)
    let url = try #require(URL(string: address))
    let request = HTTPRequest(method: .get, scheme: nil, authority: nil,
                              path: "/cdn-cgi/trace")
    var observed = Set<String>()
    for _ in 0 ..< 8 {
      let (response, body) =
          try await WinHttpTransport().send(request, body: nil, baseURL: url,
                                            operationID: "protocols")
      #expect(response.status == .ok)
      let bytes = try await collect(body)
      let text = String(decoding: bytes, as: UTF8.self)
      for line in text.split(whereSeparator: \.isNewline) {
        if line.hasPrefix("http=") { observed.insert(String(line)) }
      }
      if observed.contains("http=http/3") { return }
      try await Task.sleep(for: .milliseconds(250))
    }
    #expect(observed.contains("http=http/3"))
  }

#if DEBUG
  @Test("HTTP/2 preserves known and streaming uploads",
        .enabled(if: kHTTP2 != nil), arguments: [true, false])
  internal func multiplexing(known: Bool) async throws {
    let address = try #require(kHTTP2)
    let url = try #require(URL(string: address))
    let text = String(repeating: "x", count: 65537)
    let bytes = Array(text.utf8)
    let stream = AsyncStream<ArraySlice<UInt8>> { continuation in
      continuation.yield(bytes[...])
      continuation.finish()
    }
    let length: HTTPBody.Length = known ? .known(Int64(bytes.count)) : .unknown
    let body = HTTPBody(stream, length: length, iterationBehavior: .single)
    let request = HTTPRequest(method: .post, scheme: nil, authority: nil,
                              path: "/httpbin/post",
                              headerFields: [.contentType: "text/plain"])
    let target = try WinHttpTarget(request: request, url: url)
    let upload = try UploadRequest(fields: request.headerFields, length: length)
    let context = try RequestContext(method: request.method, target: target,
                                     streaming: upload.streaming)
    defer { context.close() }
    try context.enable(WINHTTP_PROTOCOL_FLAG_HTTP2)
    try await context.send(upload.headers, total: upload.total)
    try await upload.send(body, to: context)
    try await context.receive()
    let version = try context.protocols()
    #expect(version == WINHTTP_PROTOCOL_FLAG_HTTP2)
    let response = try context.response()
    #expect(response.status == .ok)
    let size = try response.length()
    context.expect(size)
    let result = HTTPBody(ResponseStream(context: context),
                          length: size, iterationBehavior: .single)
    let payload = try await collect(result)
    let echo = try JSONDecoder().decode(Echo.self, from: Data(payload))
    #expect(echo.data == text)
  }
#endif

  @Test("Response metadata preserves repeated and non-ASCII field values")
  internal func headers() async throws {
    let (response, body) =
        try await send(WinHttpTransport(), path: "/echo?x=a%2Fb")
    let path = try #require(HTTPField.Name("X-Path"))
    #expect(response.headerFields[path] == "/echo?x=a%2Fb")
    let repeated = try #require(HTTPField.Name("X-Repeated"))
    #expect(response.headerFields[values: repeated] == ["one", "two"])
    let name = try #require(HTTPField.Name("X-Bytes"))
    let field = try #require(response.headerFields.first { $0.name == name })
    let bytes = Array("caf".utf8) + [UInt8(0xe9)]
    #expect(field.withUnsafeBytesOfValue { Array($0) } == bytes)
    #expect(try await collect(body) == Array("hello".utf8))
  }

  @Test("Authentication challenges do not use Windows credentials")
  internal func authentication() async throws {
    let (response, body) = try await send(WinHttpTransport(), path: "/auth")
    #expect(response.status == .unauthorized)
    #expect(response.headerFields[values: .wwwAuthenticate]
        == ["Negotiate", "NTLM"])
    #expect(try await collect(body).isEmpty)
  }

  @Test("Explicit authorization is forwarded")
  internal func authorization() async throws {
    let fixture = try #require(kFixture)
    let url = try #require(URL(string: fixture))
    let token = "Bearer test-token"
    let request = HTTPRequest(method: .get, scheme: nil, authority: nil,
                              path: "/auth",
                              headerFields: [.authorization: token])
    let (response, body) =
        try await WinHttpTransport().send(request, body: nil, baseURL: url,
                                          operationID: "authorization")
    #expect(response.status == .ok)
    #expect(try await collect(body) == Array(token.utf8))
  }

  @Test("Header queries preserve fields in both temporary and overflow buffers",
        arguments: ["small", "many", "large"])
  internal func headers(mode: String) async throws(any Error) {
    let (response, body) =
        try await send(WinHttpTransport(), path: "/benchmark/\(mode)")
    #expect(response.status == .ok)
    let repeated = try #require(HTTPField.Name("X-Repeated"))
    #expect(response.headerFields[values: repeated] == ["one", "two"])
    let bytes = try #require(HTTPField.Name("X-Bytes"))
    let field = try #require(response.headerFields.first { $0.name == bytes })
    let expected = Array("caf".utf8) + [UInt8(0xe9)]
    #expect(field.withUnsafeBytesOfValue { Array($0) } == expected)
    if mode != "small" {
      let count = mode == "many" ? 24 : 12
      let size = mode == "many" ? 64 : 1024
      for index in 0 ..< count {
        let name = try #require(HTTPField.Name("X-Bench-\(index)"))
        let value = String(repeating: "x", count: size)
        #expect(response.headerFields[name] == value)
      }
    }
    #expect(try await collect(body).isEmpty)
  }

  @Test("Direct reads preserve large response bytes", arguments: [false, true])
  internal func download(chunked: Bool) async throws {
    let path = chunked ? "/chunked" : "/download"
    let (response, body) = try await send(WinHttpTransport(), path: path)
    let expected = (0 ..< 196611).map { UInt8(truncatingIfNeeded: $0) }
    #expect(response.status == .ok)
    #expect(try await collect(body) == expected)
  }

  @Test("Gzip decodes large responses", arguments: ["known", "chunked"])
  internal func compressed(mode: String) async throws {
    let path = "/compressed/gzip/\(mode)"
    let (response, result) = try await send(WinHttpTransport(), path: path)
    #expect(response.status == .ok)
    #expect(response.headerFields[.contentEncoding] == nil)
    #expect(response.headerFields[.contentLength] == nil)
    let body = try #require(result)
    #expect(body.length == .unknown)
    let expected = (0 ..< 196611).map { UInt8(truncatingIfNeeded: $0) }
    #expect(try await collect(body) == expected)
  }

  @Test("Compressed JSON reaches the decoder as UTF-8")
  internal func json() async throws {
    let (response, body) =
        try await send(WinHttpTransport(), path: "/compressed-json")
    #expect(response.headerFields[.contentEncoding] == nil)
    #expect(response.headerFields[.contentLength] == nil)
    #expect(response.headerFields[.contentType] == "application/json")
    let name = try #require(HTTPField.Name("X-Accept-Encoding"))
    let value = try #require(response.headerFields[name])
    let encodings = value.split(separator: ",").map { whitespace($0) }
    #expect(Set(encodings) == ["gzip"])
    let bytes = try await collect(body)
    let greeting = try JSONDecoder().decode(Greeting.self, from: Data(bytes))
    #expect(greeting.message == "Hello, Zoë / 東京!")
  }

  @Test("Unsupported content encodings preserve bytes and metadata")
  internal func opaque() async throws {
    let (response, body) =
        try await send(WinHttpTransport(), path: "/encoded-unknown")
    #expect(response.headerFields[.contentEncoding] == "custom")
    #expect(response.headerFields[.contentLength] == "6")
    #expect(try await collect(body) == Array("opaque".utf8))
  }

  @Test("Deflate responses remain encoded", arguments: ["known", "chunked"])
  internal func deflate(mode: String) async throws {
    let path = "/compressed/deflate/\(mode)"
    let (response, result) = try await send(WinHttpTransport(), path: path)
    #expect(response.headerFields[.contentEncoding] == "deflate")
    let body = try #require(result)
    let length = try response.length()
    #expect(body.length == length)
    let bytes = try await collect(body)
    #expect(bytes.isEmpty == false)
    #expect(bytes.count < 196611)
  }

  @Test("Invalid and truncated compressed streams fail", arguments: [
    "/compressed-invalid", "/compressed-truncated",
  ])
  internal func decoding(path: String) async throws {
    await #expect(throws: (any Error).self) {
      let (_, body) = try await send(WinHttpTransport(), path: path)
      _ = try await collect(body)
    }
  }

  @Test("Compressed responses stream before completion")
  internal func incremental() async throws {
    let clock = ContinuousClock()
    let start = clock.now
    let (_, body) =
        try await send(WinHttpTransport(), path: "/compressed-stream")
    var iterator = try #require(body).makeAsyncIterator()
    let first = try #require(try await iterator.next())
    #expect(first.isEmpty == false)
    #expect(first.count < 32768)
    #expect(start.duration(to: clock.now) < .seconds(1))
    var count = first.count
    while let chunk = try await iterator.next() { count += chunk.count }
    #expect(count == 32768)
  }

  @Test("Repeated cancellation races leave the transport usable")
  internal func races() async throws {
    let transport = WinHttpTransport()
    for _ in 0 ..< 8 {
      try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0 ..< 16 {
          group.addTask {
            let task = Task {
              let (_, body) = try await send(transport, path: "/race")
              return try await collect(body)
            }
            switch index % 3 {
            case 0:
              task.cancel()
            case 1:
              try await Task.sleep(for: .milliseconds(5))
              task.cancel()
            default:
              break
            }
            do {
              #expect(try await task.value == Array("hello".utf8))
            } catch is CancellationError {
              // Completion and cancellation may each win the race.
            }
          }
        }
        try await group.waitForAll()
      }
    }
    let (_, body) = try await send(transport, path: "/echo")
    #expect(try await collect(body) == Array("hello".utf8))
  }

  @Test("An upload rejected before reading returns its response")
  internal func rejection() async throws {
    let bytes = Array(repeating: UInt8(ascii: "x"), count: 4096)
    let body = HTTPBody(AsyncStream<ArraySlice<UInt8>> { continuation in
      continuation.yield(bytes[...])
      continuation.finish()
    }, length: .known(Int64(bytes.count)), iterationBehavior: .single)
    let transport = WinHttpTransport()
    let (response, result) =
        try await send(transport, path: "/reject", method: .post, body: body)
    #expect(response.status == .contentTooLarge)
    #expect(try await collect(result) == Array("rejected".utf8))
    let (_, next) = try await send(transport, path: "/echo")
    #expect(try await collect(next) == Array("hello".utf8))
  }

  @Test("Upload producer failures retain their original error")
  internal func failure() async throws {
    let error = OpenAPIWinHTTPError.framing("producer failed")
    let stream = AsyncThrowingStream<ArraySlice<UInt8>, any Error> {
      $0.finish(throwing: error)
    }
    let body = HTTPBody(stream, length: .unknown, iterationBehavior: .single)
    await #expect(throws: error) {
      try await send(WinHttpTransport(), path: "/echo", method: .post,
                     body: body)
    }
  }

  @Test("Disconnected uploads fail without waiting for another callback",
        arguments: [true, false])
  internal func disconnect(known: Bool) async throws {
    let bytes = Array(repeating: UInt8(ascii: "x"), count: 16777216)
    let stream = AsyncStream<ArraySlice<UInt8>> { continuation in
      continuation.yield(bytes[...])
      continuation.finish()
    }
    let length: HTTPBody.Length = known ? .known(Int64(bytes.count)) : .unknown
    let body = HTTPBody(stream, length: length, iterationBehavior: .single)
    let clock = ContinuousClock()
    let start = clock.now
    await #expect(throws: OpenAPIWinHTTPError.self) {
      try await send(WinHttpTransport(), path: "/disconnect", method: .post,
                     body: body)
    }
    #expect(start.duration(to: clock.now) < .seconds(2))
    let (_, next) = try await send(WinHttpTransport(), path: "/echo")
    #expect(try await collect(next) == Array("hello".utf8))
  }

  @Test("A zero-length response completes at EOF")
  internal func zero() async throws {
    let (response, body) = try await send(WinHttpTransport(), path: "/zero")
    #expect(response.status == .ok)
    #expect(try await collect(body).isEmpty)
  }

  @Test("Outgoing header values preserve their original bytes", arguments: [
    Array("ASCII".utf8), Array("café".utf8),
    Array(UInt8(0xa0) ... UInt8(0xff)),
  ])
  internal func values(bytes: Array<UInt8>) async throws {
    let fixture = try #require(kFixture)
    let url = try #require(URL(string: fixture))
    let name = try #require(HTTPField.Name("X-Value"))
    var fields = HTTPFields()
    fields.append(HTTPField(name: name, value: bytes))
    let request = HTTPRequest(method: .get, scheme: nil, authority: nil,
                              path: "/headers", headerFields: fields)
    let (response, body) =
        try await WinHttpTransport().send(request, body: nil, baseURL: url,
                                          operationID: "headers")
    #expect(response.status == .ok)
    #expect(try await collect(body) == bytes)
  }

  @Test("Invalid WinHTTP header values report the native error")
  internal func invalid() async throws {
    let fixture = try #require(kFixture)
    let url = try #require(URL(string: fixture))
    let name = try #require(HTTPField.Name("X-Value"))
    var fields = HTTPFields()
    fields.append(HTTPField(name: name,
                            value: Array(UInt8(0x80) ... UInt8(0xff))))
    let request = HTTPRequest(method: .get, scheme: nil, authority: nil,
                              path: "/headers", headerFields: fields)
    await #expect(throws: OpenAPIWinHTTPError.windows(code: 87)) {
      try await WinHttpTransport().send(request, body: nil, baseURL: url,
                                        operationID: "headers")
    }
  }

  @Test("Headers and the first chunk arrive before the complete response")
  internal func streaming() async throws {
    let clock = ContinuousClock()
    let start = clock.now
    let (_, body) = try await send(WinHttpTransport(), path: "/stream")
    #expect(start.duration(to: clock.now) < .seconds(1))
    var iterator = try #require(body).makeAsyncIterator()
    let first = try #require(try await iterator.next())
    #expect(first.isEmpty == false)
    #expect(first.count < 32768)
    #expect(start.duration(to: clock.now) < .seconds(1))
    var count = first.count
    while let chunk = try await iterator.next() { count += chunk.count }
    #expect(count == 32768)
  }

  @Test("A small fragment arrives before the response finishes")
  internal func fragment() async throws {
    let clock = ContinuousClock()
    let start = clock.now
    let (_, body) = try await send(WinHttpTransport(), path: "/fragment")
    var iterator = try #require(body).makeAsyncIterator()
    #expect(try await iterator.next() == [UInt8(ascii: "x")])
    #expect(start.duration(to: clock.now) < .seconds(1))
    #expect(try await iterator.next() == [UInt8(ascii: "y")])
    #expect(try await iterator.next() == nil)
  }

  @Test("Cancellation interrupts waiting for response headers")
  internal func cancellation() async throws {
    let clock = ContinuousClock()
    let transport = WinHttpTransport()
    let task = Task { try await send(transport, path: "/delay") }
    try await Task.sleep(for: .milliseconds(100))
    let start = clock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(start.duration(to: clock.now) < .seconds(1))
    let (_, body) = try await send(transport, path: "/echo")
    #expect(try await collect(body) == Array("hello".utf8))
  }

  @Test("Cancellation interrupts a pending response read")
  internal func reading() async throws {
    let (_, body) = try await send(WinHttpTransport(), path: "/stall")
    let task = Task { try await collect(body) }
    try await Task.sleep(for: .milliseconds(100))
    let clock = ContinuousClock()
    let start = clock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(start.duration(to: clock.now) < .seconds(1))
  }

  @Test("Cancellation interrupts waiting for an upload producer")
  internal func producing() async throws {
    let (stream, continuation) = AsyncStream<ArraySlice<UInt8>>.makeStream()
    defer { continuation.finish() }
    continuation.yield([1, 2, 3])
    let body = HTTPBody(stream, length: .unknown, iterationBehavior: .single)
    let task = Task {
      try await send(WinHttpTransport(), path: "/echo", method: .post,
                     body: body)
    }
    try await Task.sleep(for: .milliseconds(100))
    let clock = ContinuousClock()
    let start = clock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(start.duration(to: clock.now) < .seconds(1))
  }

  @Test("A partial upload flushes while its producer waits for the server",
        arguments: [true, false])
  internal func progress(known: Bool) async throws(any Error) {
    let path = "/upload-progress/\(UUID().uuidString)"
    let pair = AsyncStream<ArraySlice<UInt8>>.makeStream()
    let body = HTTPBody(pair.stream, length: known ? .known(65537) : .unknown,
                        iterationBehavior: .single)
    let transport = WinHttpTransport()
    let writer = Task {
      try await send(transport, path: path, method: .post, body: body)
    }
    defer {
      pair.continuation.finish()
      writer.cancel()
    }
    pair.continuation.yield([42][...])
    var ready = false
    for _ in 0 ..< 40 {
      let (_, response) = try await send(transport, path: path)
      if try await collect(response) == Array("ready".utf8) {
        ready = true
        break
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(ready)
    pair.continuation.yield(Array(repeating: UInt8(17), count: 65536)[...])
    pair.continuation.finish()
    let (response, result) = try await writer.value
    #expect(response.status == .ok)
    let expected = [42] + Array(repeating: UInt8(17), count: 65536)
    #expect(try await collect(result) == expected)
  }

  @Test("Cancellation interrupts an upload while the server is not reading")
  internal func writing() async throws {
    let bytes = Array(repeating: UInt8(ascii: "x"), count: 16 * 1024 * 1024)
    let body = HTTPBody(AsyncStream<ArraySlice<UInt8>> { continuation in
      continuation.yield(bytes[...])
      continuation.finish()
    }, length: .unknown, iterationBehavior: .single)
    let task = Task {
      try await send(WinHttpTransport(), path: "/blocked", method: .post,
                     body: body)
    }
    try await Task.sleep(for: .milliseconds(100))
    let clock = ContinuousClock()
    let start = clock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(start.duration(to: clock.now) < .seconds(1))
  }

  @Test("Abandoning an iterator closes its request while the body is retained")
  internal func abandonment() async throws {
    let transport = WinHttpTransport()
    let (_, initial) = try await send(transport, path: "/closed")
    let before = try await collect(initial)
    let (_, body) = try await send(transport, path: "/abandon")
    defer { withExtendedLifetime(body) {} }
    for try await chunk in try #require(body) {
      #expect(chunk.isEmpty == false)
      break
    }
    var after = before
    for _ in 0 ..< 20 {
      let (_, result) = try await send(transport, path: "/closed")
      after = try await collect(result)
      if after != before { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(after != before)
  }

  @Test("A truncated response fails during iteration")
  internal func truncation() async throws {
    let (_, body) = try await send(WinHttpTransport(), path: "/truncated")
    await #expect(throws: (any Error).self) { try await collect(body) }
  }

  @Test("A declared upload length is enforced")
  internal func mismatch() async throws {
    let body = HTTPBody(AsyncStream<ArraySlice<UInt8>> { continuation in
      continuation.yield([1, 2])
      continuation.finish()
    }, length: .known(3), iterationBehavior: .single)
    await #expect(throws: OpenAPIWinHTTPError.self) {
      try await send(WinHttpTransport(), path: "/echo", method: .post,
                     body: body)
    }
  }

  @Test("HEAD and 204 responses have no body")
  internal func empty() async throws {
    let transport = WinHttpTransport()
    let (_, head) = try await send(transport, path: "/echo", method: .head)
    #expect(head == nil)
    let (response, body) = try await send(transport, path: "/empty")
    #expect(response.status == .noContent)
    #expect(body == nil)
  }

  @Test("Redirects return their status without replaying requests")
  internal func redirects() async throws {
    let (response, body) = try await send(WinHttpTransport(), path: "/redirect")
    #expect(response.status.code == 302)
    #expect(response.headerFields[.location] == "/echo")
    #expect(try await collect(body).isEmpty)
  }

  @Test("Independent transports reuse pooled connections")
  internal func reuse() async throws {
    var ports = Set<String>()
    let name = try #require(HTTPField.Name("X-Port"))
    for _ in 0 ..< 8 {
      let (response, body) = try await send(WinHttpTransport(), path: "/echo")
      try ports.insert(#require(response.headerFields[name]))
      _ = try await collect(body)
    }
    #expect(ports.count < 8)
  }

  @Test("One transport supports concurrent requests")
  internal func concurrency() async throws {
    let transport = WinHttpTransport()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0 ..< 32 {
        group.addTask {
          let (_, body) = try await send(transport, path: "/echo")
          #expect(try await collect(body) == Array("hello".utf8))
        }
      }
      try await group.waitForAll()
    }
  }
}
