// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

private import WinSDK

/// Errors reported by the transport. Cancellation throws `CancellationError`.
public enum OpenAPIWinHTTPError: Error, Equatable, Sendable {
  case windows(code: UInt32)
  case framing(String)
  case length(expected: Int64, actual: Int64)
  case headers
  case concurrent
}

extension OpenAPIWinHTTPError: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .windows(dwMessageId):
      var buffer = Array<UInt16>(repeating: 0, count: 2048)
      let dwFlags = FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS
      let count = buffer.withUnsafeMutableBufferPointer { buffer in
        let lpBuffer = buffer.baseAddress
        let nSize = DWORD(buffer.count)
        return FormatMessageW(dwFlags, nil, dwMessageId, 0, lpBuffer, nSize, nil)
      }
      let text = String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
      let message = text.prefix(while: { $0.isNewline == false })
      return message.isEmpty ? "WinHTTP error \(dwMessageId)"
                             : "WinHTTP error \(dwMessageId): \(message)"
    case let .framing(reason):
      return "Invalid HTTP body framing: \(reason)"
    case let .length(expected, actual):
      return "HTTP body length mismatch: expected \(expected), got \(actual)"
    case .headers:
      return "Invalid HTTP headers"
    case .concurrent:
      return "Concurrent operations on one HTTP body are unsupported"
    }
  }
}
