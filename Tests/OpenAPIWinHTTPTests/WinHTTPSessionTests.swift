// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

private import CWinHTTP
internal import Testing
@testable internal import OpenAPIWinHTTPTransport

internal struct WinHTTPSessionTests {
  @Test("Callback registration distinguishes success, replacement, and failure")
  internal func callback() throws(OpenAPIWinHTTPError) {
    let session = try WinHTTPSession()
    let lpfnInternetCallback: WINHTTP_STATUS_CALLBACK = { _, _, _, _, _ in
    }
    let lpfnInitialCallback =
        WinHttpSetStatusCallback(session.hSession, lpfnInternetCallback,
                                 WINHTTP_CALLBACK_FLAG_HANDLES, 0)
    let initial = unsafeBitCast(lpfnInitialCallback, to: UnsafeRawPointer?.self)
    #expect(initial == nil)
    let lpfnPreviousCallback =
        WinHttpSetStatusCallback(session.hSession, nil,
                                 WINHTTP_CALLBACK_FLAG_HANDLES, 0)
    let previous =
        unsafeBitCast(lpfnPreviousCallback, to: UnsafeRawPointer?.self)
    let expected =
        unsafeBitCast(lpfnInternetCallback, to: UnsafeRawPointer.self)
    #expect(previous == expected)
    let lpfnFailedCallback =
        WinHttpSetStatusCallback(nil, lpfnInternetCallback,
                                 WINHTTP_CALLBACK_FLAG_HANDLES, 0)
    let failed = unsafeBitCast(lpfnFailedCallback, to: UnsafeRawPointer?.self)
    #expect(failed == WINHTTP_INVALID_STATUS_CALLBACK)
  }

  @Test("All callers share the process-wide WinHTTP session")
  internal func reuse() async throws {
    var handles = Set<UInt>()
    try await withThrowingTaskGroup(of: UInt.self) { group in
      for _ in 0 ..< 32 {
        group.addTask { UInt(bitPattern: try WinHTTPSession.get()) }
      }
      for try await handle in group {
        handles.insert(handle)
      }
    }
    #expect(handles.count == 1)
  }
}
