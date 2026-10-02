// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

#if DEBUG
private import class Foundation.ProcessInfo
private import struct FoundationEssentials.URL
private import CWinHTTP
private import WinSDK
internal import HTTPTypes
internal import OpenAPIRuntime
internal import Testing
internal import OpenAPIWinHTTPTransport

private let kMultiplex =
    ProcessInfo.processInfo.environment["WINHTTP_TEST_MULTIPLEX_URL"]

private let kProxy = ProcessInfo.processInfo.environment["WINHTTP_TEST_PROXY"]

private let kProtocols: Array<UInt32> = [WINHTTP_PROTOCOL_FLAG_HTTP2,
                                      WINHTTP_PROTOCOL_FLAG_HTTP3]

@Suite(.serialized, .enabled(if: kMultiplex != nil))
internal struct ProtocolTests {
  private struct ProxySession: ~Copyable {
    internal let hSession: HINTERNET

    internal init(_ address: String) throws(OpenAPIWinHTTPError) {
      let hSession = address.withCString(encodedAs: UTF16.self) { pszProxyW in
        WinHttpOpen(nil, WINHTTP_ACCESS_TYPE_NAMED_PROXY, pszProxyW,
                    WINHTTP_NO_PROXY_BYPASS, WINHTTP_FLAG_ASYNC)
      }
      guard let hSession else {
        throw .windows(code: GetLastError())
      }
      self.hSession = hSession
    }

    deinit {
      _ = WinHttpCloseHandle(hSession)
    }
  }

  private func send(_ path: String, protocol version: UInt32,
                    body: HTTPBody? = nil, verify: Bool = true,
                    expected: UInt32? = nil, session hSession: HINTERNET? = nil)
      async throws -> (HTTPResponse, HTTPBody?) {
    let address = try #require(kMultiplex)
    let fixture = try #require(URL(string: address))
    #expect(fixture.host == "localhost")
    let port = try #require(fixture.port)
    let proxied = "https://winhttp.fixture.invalid:\(port)"
    let url = if hSession == nil {
      fixture
    } else {
      try #require(URL(string: proxied))
    }
    let request = HTTPRequest(method: body == nil ? .get : .post, scheme: nil,
                              authority: nil, path: path)
    let target = try WinHttpTarget(request: request, url: url)
    let upload =
        try UploadRequest(fields: request.headerFields, length: body?.length)
    let context = try RequestContext(method: request.method, target: target,
                                     streaming: upload.streaming,
                                     session: hSession)
    return try await withTaskCancellationHandler {
      do {
        try context.enable(version, local: true)
        try await context.send(upload.headers, total: upload.total)
        try await upload.send(body, to: context)
        try await context.receive()
        if verify {
          let negotiated = try context.protocols()
          #expect(negotiated == (expected ?? version))
        }
        let response = try context.response()
        let length = try response.length()
        context.expect(length)
        let body = HTTPBody(ResponseStream(context: context), length: length,
                            iterationBehavior: .single)
        return (response, body)
      } catch {
        context.close(error: error)
        throw error
      }
    } onCancel: {
      context.close(error: CancellationError())
    }
  }

  private func collect(_ body: HTTPBody?) async throws -> Array<UInt8> {
    var bytes = Array<UInt8>()
    for try await chunk in try #require(body) {
      bytes.append(contentsOf: chunk)
    }
    return bytes
  }

  private func warm(_ version: UInt32) async throws {
    for _ in 0 ..< 10 {
      let (response, body) = try await send("/warm", protocol: version,
                                            verify: false)
      _ = try await collect(body)
      let name = try #require(HTTPField.Name("X-Protocol"))
      let expected = version == WINHTTP_PROTOCOL_FLAG_HTTP2 ? "h2" : "h3"
      if response.headerFields[name] == expected {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    Issue.record("The fixture did not negotiate the requested protocol")
  }

  @Test("HTTP/2 and HTTP/3 preserve known and streaming uploads",
        arguments: kProtocols, [true, false])
  internal func upload(version: UInt32, known: Bool) async throws {
    try await warm(version)
    let bytes = (0 ..< 196611).map { UInt8(truncatingIfNeeded: $0) }
    let stream = AsyncStream<ArraySlice<UInt8>> { continuation in
      continuation.yield(bytes[..<97])
      continuation.yield(bytes[97...])
      continuation.finish()
    }
    let length: HTTPBody.Length = known ? .known(Int64(bytes.count)) : .unknown
    let body = HTTPBody(stream, length: length, iterationBehavior: .single)
    let (response, result) =
        try await send("/echo", protocol: version, body: body)
    #expect(response.status == .ok)
    #expect(try await collect(result) == bytes)
  }

  @Test("Protocol cancellation interrupts headers, reads and producers",
        arguments: kProtocols)
  internal func cancellation(version: UInt32) async throws {
    try await warm(version)
    let headers = Task { try await send("/delay", protocol: version) }
    try await Task.sleep(for: .milliseconds(100))
    headers.cancel()
    await #expect(throws: CancellationError.self) { try await headers.value }

    let (_, body) = try await send("/stall", protocol: version)
    let reader = Task { try await collect(body) }
    try await Task.sleep(for: .milliseconds(100))
    reader.cancel()
    await #expect(throws: CancellationError.self) { try await reader.value }

    let (stream, producer) = AsyncStream<ArraySlice<UInt8>>.makeStream()
    defer { producer.finish() }
    producer.yield([1, 2, 3])
    let upload = HTTPBody(stream, length: .unknown, iterationBehavior: .single)
    let writer = Task {
      try await send("/echo", protocol: version, body: upload)
    }
    try await Task.sleep(for: .milliseconds(100))
    writer.cancel()
    await #expect(throws: CancellationError.self) { try await writer.value }
    let (_, result) = try await send("/warm", protocol: version)
    #expect(try await collect(result) == Array("hello".utf8))
  }

  @Test("Concurrent streams share connections without sharing response bytes",
        arguments: kProtocols)
  internal func concurrent(version: UInt32) async throws {
    try await warm(version)
    let name = try #require(HTTPField.Name("X-Connection"))
    let connections =
        try await withThrowingTaskGroup(of: String.self) { group in
      for index in 0 ..< 8 {
        group.addTask {
          let bytes = Array(repeating: UInt8(index), count: 196611)
          let stream = AsyncStream<ArraySlice<UInt8>> { continuation in
            continuation.yield(bytes[...])
            continuation.finish()
          }
          let body = HTTPBody(stream, length: .unknown,
                              iterationBehavior: .single)
          let (response, result) =
              try await send("/parallel", protocol: version, body: body)
          #expect(try await collect(result) == bytes)
          return try #require(response.headerFields[name])
        }
      }
      var connections = Set<String>()
      for try await connection in group { connections.insert(connection) }
      return connections
    }
    #expect(connections.count == 1)
  }

  @Test("Cancellation races preserve sibling protocol streams",
        arguments: kProtocols)
  internal func races(version: UInt32) async throws {
    try await warm(version)
    let expected = Array(repeating: UInt8(ascii: "x"), count: 32768)
    let survivor = Task {
      let (_, body) = try await send("/stream", protocol: version)
      return try await collect(body)
    }
    for index in 0 ..< 32 {
      let task = Task {
        let (_, body) = try await send("/stream", protocol: version)
        return try await collect(body)
      }
      if index.isMultiple(of: 2) {
        task.cancel()
      } else {
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
      }
      do {
        #expect(try await task.value == expected)
      } catch is CancellationError {
        // Completion and cancellation may each win the race.
      }
    }
    #expect(try await survivor.value.count == 32768)
    let (_, body) = try await send("/warm", protocol: version)
    #expect(try await collect(body) == Array("hello".utf8))
  }

  @Test("CONNECT proxies preserve HTTP/2 with HTTP/3 enabled",
        .enabled(if: kProxy != nil))
  internal func proxy() async throws {
    let proxy = try ProxySession(#require(kProxy))
    defer { withExtendedLifetime(proxy) {} }
    let bytes = (0 ..< 65537).map { UInt8(truncatingIfNeeded: $0) }
    let stream = AsyncStream<ArraySlice<UInt8>> { continuation in
      continuation.yield(bytes[...])
      continuation.finish()
    }
    let body = HTTPBody(stream, length: .unknown, iterationBehavior: .single)
    let protocols = WINHTTP_PROTOCOL_FLAG_HTTP2 | WINHTTP_PROTOCOL_FLAG_HTTP3
    let (response, result) =
        try await send("/echo", protocol: protocols, body: body,
                       expected: WINHTTP_PROTOCOL_FLAG_HTTP2,
                       session: proxy.hSession)
    #expect(response.status == .ok)
    #expect(try await collect(result) == bytes)
    let name = try #require(HTTPField.Name("X-Proxy"))
    let tunnels = try #require(response.headerFields[name].flatMap(Int.init))
    #expect(tunnels > 0)
  }

  @Test("Advanced responses stream before completion",
        arguments: kProtocols)
  internal func streaming(version: UInt32) async throws {
    try await warm(version)
    let clock = ContinuousClock()
    let start = clock.now
    let (_, body) = try await send("/stream", protocol: version)
    var iterator = try #require(body).makeAsyncIterator()
    let first = try #require(try await iterator.next())
    #expect(first.isEmpty == false)
    #expect(start.duration(to: clock.now) < .seconds(1))
    var count = first.count
    while let chunk = try await iterator.next() { count += chunk.count }
    #expect(count == 32768)
  }
}
#endif
