// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

package import HTTPTypes
package import OpenAPIRuntime

package struct UploadRequest: Sendable {
  private typealias Yield =
      @Sendable (ArraySlice<UInt8>) async throws(any Error) -> Void

  package let expected: Int64?
  package let streaming: Bool
  package let total: UInt32
  package let headers: Array<UInt16>

  package init(fields: HTTPFields, length: HTTPBody.Length?)
      throws(OpenAPIWinHTTPError) {
    var fields = fields
    let declared = try fields.length()
    let encoding = fields[.transferEncoding].map {
      whitespace($0[...]).lowercased()
    }
    if let encoding, encoding != "chunked" {
      throw .framing("only chunked Transfer-Encoding is supported")
    }
    guard declared == nil || encoding == nil else {
      throw .framing("Content-Length and Transfer-Encoding cannot coexist")
    }

    switch length ?? .known(0) {
    case let .known(count):
      guard count >= 0, declared == nil || declared == count else {
        throw .framing("Content-Length does not match the body")
      }
      expected = count
    case .unknown:
      expected = declared
    }

    if let count = expected, encoding == nil {
      streaming = false
      if length != nil || declared != nil {
        fields[.contentLength] = String(count)
      }
      total = UInt32(exactly: count) ?? WINHTTP_IGNORE_REQUEST_TOTAL_LENGTH
    } else {
      streaming = true
      fields[.contentLength] = nil
      fields[.transferEncoding] = nil
      total = WINHTTP_IGNORE_REQUEST_TOTAL_LENGTH
    }

    var headers = Array<UInt16>()
    let capacity = fields.reduce(0) { count, field in
      let name = field.name.rawName.utf8.count
      let value = field.withUnsafeBytesOfValue { $0.count }
      return count + name + value + 4
    }
    headers.reserveCapacity(capacity)
    for field in fields {
      for byte in field.name.rawName.utf8 {
        headers.append(UInt16(byte))
      }
      headers.append(UInt16(UInt8(ascii: ":")))
      headers.append(UInt16(UInt8(ascii: " ")))
      // Each Latin-1 byte is the same UTF-16 code unit. HTTPField validates
      // names; WinHTTP continues to validate the native header syntax.
      field.withUnsafeBytesOfValue { bytes in
        for byte in bytes {
          headers.append(UInt16(byte))
        }
      }
      headers.append(UInt16(UInt8(ascii: "\r")))
      headers.append(UInt16(UInt8(ascii: "\n")))
    }
    self.headers = headers
  }

  package func send(_ body: HTTPBody?, to context: RequestContext)
      async throws(any Error) {
    if let expected, expected <= RequestContext.capacity {
      // Small known bodies need no producer task or queue.
      try await produce(body) { chunk in
        let batch = UploadBuffer.Batch(chunks: [chunk], count: chunk.count)
        try await UploadRequest.write(batch, to: context)
      }
    } else {
      let buffer = UploadBuffer()
      try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask {
            do {
              try await produce(body) { try await buffer.append($0) }
              buffer.finish()
            } catch {
              buffer.finish(error: error)
              throw error
            }
          }
          group.addTask {
            do {
              while let batch = try await buffer.next() {
                try await UploadRequest.write(batch, to: context)
              }
            } catch {
              buffer.finish(error: error)
              throw error
            }
          }
          defer { group.cancelAll() }
          while try await group.next() != nil {}
        }
      } onCancel: {
        buffer.finish(error: CancellationError())
      }
    }
    if streaming { try await context.end() }
    try Task.checkCancellation()
  }

  private static func write(_ batch: UploadBuffer.Batch,
                            to context: RequestContext) async
      throws(any Error) {
    try await context.write(count: batch.count) { output in
      output.withUnsafeMutableBufferPointer { buffer, initialized in
        var offset = 0
        for chunk in batch.chunks {
          precondition(chunk.count <= buffer.count - offset)
          chunk.span.withUnsafeBytes { source in
            let start = buffer.baseAddress! + offset
            let destination =
                UnsafeMutableRawBufferPointer(start: start, count: chunk.count)
            destination.copyMemory(from: source)
          }
          offset += chunk.count
        }
        initialized = offset
      }
    }
  }

  private func produce(_ body: HTTPBody?, _ yield: Yield) async
      throws(any Error) {
    var sent: Int64 = 0
    if let body {
      for try await chunk in body {
        try Task.checkCancellation()
        let (count, overflow) = sent.addingReportingOverflow(Int64(chunk.count))
        guard overflow == false else {
          throw OpenAPIWinHTTPError.framing("body is too large")
        }
        if let expected, count > expected {
          throw OpenAPIWinHTTPError.length(expected: expected, actual: count)
        }
        sent = count

        var offset = 0
        while offset < chunk.count {
          let count = min(chunk.count - offset, RequestContext.capacity)
          let start = chunk.index(chunk.startIndex, offsetBy: offset)
          let end = chunk.index(start, offsetBy: count)
          try await yield(chunk[start ..< end])
          offset += count
        }
      }
    }
    if let expected, sent != expected {
      throw OpenAPIWinHTTPError.length(expected: expected, actual: sent)
    }
  }
}
