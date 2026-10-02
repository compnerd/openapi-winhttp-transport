// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import Testing
internal import OpenAPIWinHTTPTransport

internal struct UploadBufferTests {
  @Test("Ready slices share a batch and retain their original indices")
  internal func batching() async throws(any Error) {
    let buffer = UploadBuffer()
    let bytes = Array(UInt8(0) ... UInt8(31))
    try await buffer.append(bytes[3 ..< 7])
    try await buffer.append(bytes[11 ..< 19])
    buffer.finish()
    let batch = try #require(try await buffer.next())
    #expect(batch.count == 12)
    let expected = Array(bytes[3 ..< 7]) + Array(bytes[11 ..< 19])
    #expect(batch.chunks.flatMap { $0 } == expected)
    #expect(try await buffer.next() == nil)
  }

  @Test("A full queue pauses its producer until drained")
  internal func backpressure() async throws(any Error) {
    let buffer = UploadBuffer()
    let bytes = Array(repeating: UInt8(42), count: RequestContext.capacity)
    try await buffer.append(bytes[...])
    let producer = Task {
      try await buffer.append([17][...])
      buffer.finish()
    }
    let first = try #require(try await buffer.next())
    #expect(first.count == RequestContext.capacity)
    try await producer.value
    let last = try #require(try await buffer.next())
    #expect(last.chunks.flatMap { $0 } == [17])
    #expect(try await buffer.next() == nil)
  }

  @Test("Failures wake readers and writers and preserve the original error",
        arguments: [true, false])
  internal func failure(writing: Bool) async throws(any Error) {
    let buffer = UploadBuffer()
    let error = OpenAPIWinHTTPError.framing("producer failed")
    if writing {
      let bytes = Array(repeating: UInt8(42), count: RequestContext.capacity)
      try await buffer.append(bytes[...])
    }
    let pending = Task {
      if writing {
        try await buffer.append([17][...])
      } else {
        _ = try await buffer.next()
      }
    }
    buffer.finish(error: error)
    await #expect(throws: error) { try await pending.value }
    await #expect(throws: error) { try await buffer.next() }
  }

  @Test("Repeated backpressure preserves batch lengths and slices")
  internal func stress() async throws(any Error) {
    let buffer = UploadBuffer()
    let bytes = Array(repeating: UInt8(42), count: 1024)
    let iterations = 10000
    try await withThrowingTaskGroup(of: Int.self) { group in
      group.addTask {
        for _ in 0 ..< iterations { try await buffer.append(bytes[...]) }
        buffer.finish()
        return 0
      }
      group.addTask {
        var received = 0
        while let batch = try await buffer.next() {
          #expect(batch.count <= RequestContext.capacity)
          #expect(batch.chunks.reduce(0) { $0 + $1.count } == batch.count)
          received += batch.count
          await Task.yield()
        }
        return received
      }
      var received = 0
      for try await count in group { received += count }
      #expect(received == iterations * bytes.count)
    }
  }
}
