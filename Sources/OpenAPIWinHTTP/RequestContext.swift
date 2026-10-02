// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

@_implementationOnly
package import CWinHTTP
package import HTTPTypes
package import OpenAPIRuntime
package import WinSDK

// The lock protects mutable state. The callback retain preserves the context
// and I/O buffer through HANDLE_CLOSING, even after cancellation.
package final class RequestContext: @unchecked Sendable {
  package static let capacity = 64 * 1024

  private let lock = CriticalSection()
  private var lpBuffer: UnsafeMutableRawPointer?

  private var hConnect: HINTERNET?
  private var hRequest: HINTERNET?

  private var dwInternetStatus: DWORD = 0
  private var continuation: CheckedContinuation<Completion, any Error>?

  private var failure: (any Error)?
  private var finished = false

  private var length: Int64?
  private var received: Int64 = 0

  // MARK: - Lifetime

  package init(method: borrowing HTTPRequest.Method,
               target: borrowing WinHttpTarget, streaming: Bool,
               session hSession: HINTERNET? = nil)
      throws(OpenAPIWinHTTPError) {
    let hSession = if let hSession {
      hSession
    } else {
      try WinHTTPSession.get()
    }

    guard let hConnect = target.host.withCString(encodedAs: UTF16.self, {
      pswzServerName in
      WinHttpConnect(hSession, pswzServerName, target.port, 0)
    }) else {
      throw .windows(code: GetLastError())
    }

    let dwFlags = (target.secure ? WINHTTP_FLAG_SECURE : 0)
                | (streaming ? WINHTTP_FLAG_AUTOMATIC_CHUNKING : 0)
    guard let hRequest =
        method.rawValue.withCString(encodedAs: UTF16.self, { pwszVerb in
          target.path.withCString(encodedAs: UTF16.self) { pwszObjectName in
            WinHttpOpenRequest(hConnect, pwszVerb, pwszObjectName, nil,
                               WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                               dwFlags)
          }
        }) else {
      let dwError = GetLastError()
      _ = WinHttpCloseHandle(hConnect)
      throw .windows(code: dwError)
    }

    self.hConnect = hConnect
    self.hRequest = hRequest

    do {
      try configure(hRequest)
    } catch {
      close(error: error)
      throw error
    }
  }

  private func configure(_ hRequest: HINTERNET) throws(OpenAPIWinHTTPError) {
    try lock.withLock { () throws(OpenAPIWinHTTPError) in
      // Redirects can replay single-use uploads or leak custom credentials.
      // Cookies and Windows credentials must not introduce implicit state.
      var dwDisabledFeatures = WINHTTP_DISABLE_AUTHENTICATION
                             | WINHTTP_DISABLE_COOKIES
                             | WINHTTP_DISABLE_REDIRECTS
      guard WinHttpSetOption(hRequest, WINHTTP_OPTION_DISABLE_FEATURE,
                             &dwDisabledFeatures,
                             DWORD(MemoryLayout<DWORD>.size)) else {
        throw .windows(code: GetLastError())
      }

      let lpContext = Unmanaged.passUnretained(self).toOpaque()

      var dwContext = DWORD_PTR(UInt(bitPattern: lpContext))
      guard WinHttpSetOption(hRequest, WINHTTP_OPTION_CONTEXT_VALUE, &dwContext,
                             DWORD(MemoryLayout<DWORD_PTR>.size)) else {
        throw .windows(code: GetLastError())
      }


      let callback: WINHTTP_STATUS_CALLBACK = { _, dwContext, dwInternetStatus, lpvStatusInformation, dwStatusInformationLength in
        guard let lpContext =
            UnsafeRawPointer(bitPattern: UInt(dwContext)) else {
          return
        }

        let reference = Unmanaged<RequestContext>.fromOpaque(lpContext)
        if dwInternetStatus == WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING {
          // The final notification releases the handle's ownership after all
          // earlier callbacks and accesses to its I/O buffer have finished.
          let request = reference.takeRetainedValue()
          request.closed()
        } else {
          let request = reference.takeUnretainedValue()
          request.completed(dwInternetStatus, lpvStatusInformation,
                            dwStatusInformationLength)
        }
      }
      let dwNotificationFlags = WINHTTP_CALLBACK_FLAG_ALL_COMPLETIONS
                              | WINHTTP_CALLBACK_FLAG_HANDLES
      let lpfnPreviousCallback =
          WinHttpSetStatusCallback(hRequest, callback, dwNotificationFlags, 0)

      let lpfnCallback =
          unsafeBitCast(lpfnPreviousCallback, to: UnsafeRawPointer?.self)
      if lpfnCallback == WINHTTP_INVALID_STATUS_CALLBACK {
        throw .windows(code: GetLastError())
      }

      // No operation has started; callbacks cannot race this retain.
      _ = Unmanaged.passRetained(self)
    }
  }

  deinit {
    if let hRequest {
      _ = WinHttpCloseHandle(hRequest)
    }
    if let hConnect {
      _ = WinHttpCloseHandle(hConnect)
    }
    lpBuffer?.deallocate()
  }

  // Called under the lock before starting I/O. The callback retain keeps the
  // allocation alive until HANDLE_CLOSING, including after cancellation.
  private func allocate() -> UnsafeMutableRawPointer {
    if let lpBuffer { return lpBuffer }
    let lpBuffer =
        UnsafeMutableRawPointer.allocate(byteCount: RequestContext.capacity,
                                         alignment: 16)
    _ = lpBuffer.bindMemory(to: UInt8.self, capacity: RequestContext.capacity)
    self.lpBuffer = lpBuffer
    return lpBuffer
  }

  package func finish() {
    lock.withLock {
      finished = true
      close()
    }
  }

  package func close(error: (any Error)? = nil) {
    lock.withLock {
      if let error, failure == nil {
        failure = error
      }

      if finished == false, failure == nil {
        failure = CancellationError()
      }

      let continuation = self.continuation
      let hRequest = self.hRequest

      // Detach pending work before resuming it or triggering closing callbacks.
      self.continuation = nil
      self.hRequest = nil

      continuation?.resume(throwing: failure ?? CancellationError())
      if let hRequest {
        _ = WinHttpCloseHandle(hRequest)
      }
    }
  }

  private func closed() {
    lock.withLock {
      // Release the parent after the request's final closing notification.
      if let hConnect {
        self.hConnect = nil
        _ = WinHttpCloseHandle(hConnect)
      }
    }
  }

  // MARK: - Request

  package func send(_ headers: Array<UInt16>, total dwTotalLength: UInt32)
      async throws(any Error) {
    guard let dwHeadersLength = DWORD(exactly: headers.count) else {
      throw OpenAPIWinHTTPError.headers
    }
    let dwInternetStatus = WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE
    _ = try await perform(dwInternetStatus) { hRequest in
      headers.withUnsafeBufferPointer { headers in
        let lpContext = Unmanaged.passUnretained(self).toOpaque()
        let dwContext = DWORD_PTR(UInt(bitPattern: lpContext))
        let lpszHeaders = headers.isEmpty ? WINHTTP_NO_ADDITIONAL_HEADERS
                                          : headers.baseAddress
        return WinHttpSendRequest(hRequest, lpszHeaders, dwHeadersLength,
                                  WINHTTP_NO_REQUEST_DATA, 0, dwTotalLength,
                                  dwContext)
      }
    }
  }

  internal func write(count: Int,
                      _ fill: @Sendable (inout OutputSpan<UInt8>) -> Void) async
      throws {
    guard count > 0, count <= RequestContext.capacity else {
      throw OpenAPIWinHTTPError.framing("write exceeds buffer capacity")
    }
    var offset = 0
    let dwInternetStatus = WINHTTP_CALLBACK_STATUS_WRITE_COMPLETE
    while offset < count {
      let start = offset
      let result = try await perform(dwInternetStatus) { hRequest in
        let lpBuffer = self.allocate()
        if start == 0 {
          // The view is scoped to preparation; the context owns the bytes
          // through completion or cancellation's final closing callback.
          let lpBytes = lpBuffer.assumingMemoryBound(to: UInt8.self)
          let bytes = UnsafeMutableBufferPointer(start: lpBytes, count: count)
          var span = OutputSpan<UInt8>(buffer: bytes, initializedCount: 0)
          fill(&span)
          let initialized = span.finalize(for: bytes)
          precondition(initialized == count)
        }
        let dwNumberOfBytesToWrite = DWORD(count - start)
        return WinHttpWriteData(hRequest, lpBuffer + start,
                                dwNumberOfBytesToWrite, nil)
      }
      guard case let .written(written) = result,
          written > 0, written <= count - start else {
        throw OpenAPIWinHTTPError.framing("write made no progress")
      }
      offset += written
    }
  }

  internal func end() async throws {
    _ = try await perform(WINHTTP_CALLBACK_STATUS_WRITE_COMPLETE) { hRequest in
      WinHttpWriteData(hRequest, WINHTTP_NO_REQUEST_DATA, 0, nil)
    }
  }

  package func receive() async throws {
    _ = try await perform(WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE) { hRequest in
      WinHttpReceiveResponse(hRequest, nil)
    }
  }

  // MARK: - Response

#if DEBUG
  // Test the negotiated protocol without adding public transport metadata.
  package func enable(_ dwProtocols: DWORD, local: Bool = false) throws {
    try lock.withLock {
      guard let hRequest else {
        throw CancellationError()
      }

      if local {
        // Test fixtures supply a localhost certificate without changing trust.
        var dwSecurityFlags = SECURITY_FLAG_IGNORE_UNKNOWN_CA
        guard WinHttpSetOption(hRequest, WINHTTP_OPTION_SECURITY_FLAGS,
                               &dwSecurityFlags,
                               DWORD(MemoryLayout<DWORD>.size)) else {
          throw OpenAPIWinHTTPError.windows(code: GetLastError())
        }
      }
      var dwProtocols = dwProtocols
      let dwBufferLength = DWORD(MemoryLayout.size(ofValue: dwProtocols))
      guard WinHttpSetOption(hRequest, WINHTTP_OPTION_ENABLE_HTTP_PROTOCOL,
                             &dwProtocols, dwBufferLength) else {
        throw OpenAPIWinHTTPError.windows(code: GetLastError())
      }
    }
  }

  package func protocols() throws -> DWORD {
    try lock.withLock {
      guard let hRequest else {
        throw CancellationError()
      }

      var dwProtocols: DWORD = 0
      var dwBufferLength = DWORD(MemoryLayout.size(ofValue: dwProtocols))
      guard WinHttpQueryOption(hRequest, WINHTTP_OPTION_HTTP_PROTOCOL_USED,
                               &dwProtocols, &dwBufferLength) else {
        throw OpenAPIWinHTTPError.windows(code: GetLastError())
      }
      return dwProtocols
    }
  }
#endif

  package func response() throws -> HTTPResponse {
    try lock.withLock {
      if let failure {
        throw failure
      }

      guard let hRequest else {
        throw CancellationError()
      }

      var dwStatusCode: DWORD = 0
      var dwBufferLength = DWORD(MemoryLayout.size(ofValue: dwStatusCode))
      let dwInfoLevel = WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER
      guard WinHttpQueryHeaders(hRequest, dwInfoLevel,
                                WINHTTP_HEADER_NAME_BY_INDEX, &dwStatusCode,
                                &dwBufferLength, WINHTTP_NO_HEADER_INDEX) else {
        throw OpenAPIWinHTTPError.windows(code: GetLastError())
      }
      guard (100 ... 999).contains(dwStatusCode) else {
        throw OpenAPIWinHTTPError.headers
      }

      let dwRawInfoLevel = WINHTTP_QUERY_RAW_HEADERS_CRLF
      // Most header blocks fit in 8 KiB of UTF-16 storage. Try that first to
      // avoid a sizing query and a zero-initialized heap allocation.
      let text =
          try withUnsafeTemporaryAllocation(of: UInt16.self,
                                            capacity: 4096) { buffer in
        var dwHeadersLength = DWORD(buffer.count * MemoryLayout<UInt16>.size)
        if WinHttpQueryHeaders(hRequest, dwRawInfoLevel,
                               WINHTTP_HEADER_NAME_BY_INDEX, buffer.baseAddress,
                               &dwHeadersLength, WINHTTP_NO_HEADER_INDEX) {
          return String(decoding: buffer.prefix(Int(dwHeadersLength) / 2),
                        as: UTF16.self)
        }
        let dwError = GetLastError()
        guard dwError == ERROR_INSUFFICIENT_BUFFER else {
          throw OpenAPIWinHTTPError.windows(code: dwError)
        }
        let capacity = Int(dwHeadersLength) / MemoryLayout<UInt16>.size
        return try withUnsafeTemporaryAllocation(of: UInt16.self,
                                                 capacity: capacity) { buffer in
          guard WinHttpQueryHeaders(hRequest, dwRawInfoLevel,
                                    WINHTTP_HEADER_NAME_BY_INDEX,
                                    buffer.baseAddress, &dwHeadersLength,
                                    WINHTTP_NO_HEADER_INDEX) else {
            throw OpenAPIWinHTTPError.windows(code: GetLastError())
          }
          // The successful byte count excludes the terminating UTF-16 null.
          return String(decoding: buffer.prefix(Int(dwHeadersLength) / 2),
                        as: UTF16.self)
        }
      }
      var response =
          HTTPResponse(status: HTTPResponse.Status(code: Int(dwStatusCode)))
      for line in text.split(separator: "\r\n").dropFirst() {
        guard let colon = line.firstIndex(of: ":"),
            let name = HTTPField.Name(String(line[..<colon])) else {
          throw OpenAPIWinHTTPError.headers
        }
        let value = whitespace(line[line.index(after: colon)...])
        let capacity = value.utf8.count
        let field =
            try withUnsafeTemporaryAllocation(of: UInt8.self,
                                              capacity: capacity) { buffer in
          var count = 0
          for scalar in value.unicodeScalars {
            guard let byte = UInt8(exactly: scalar.value) else {
              throw OpenAPIWinHTTPError.headers
            }
            buffer[count] = byte
            count += 1
          }
          return HTTPField(name: name, value: buffer.prefix(count))
        }
        response.headerFields.append(field)
      }
      return response
    }
  }

  package func expect(_ length: HTTPBody.Length) {
    lock.withLock {
      if case let .known(count) = length { self.length = count }
    }
  }

  internal func read() async throws -> ArraySlice<UInt8>? {
    do {
      try Task.checkCancellation()
      if lock.withLock({ finished }) { return nil }

      let dwInternetStatus = WINHTTP_CALLBACK_STATUS_READ_COMPLETE
      let dwNumberOfBytesToRead = DWORD(RequestContext.capacity)
      let result = try await perform(dwInternetStatus) { hRequest in
        let lpBuffer = self.allocate()
        // No FILL_BUFFER flag: complete as soon as any bytes arrive.
        let dwError = WinHttpReadDataEx(hRequest, lpBuffer,
                                        dwNumberOfBytesToRead, nil, 0, 0, nil)
        if dwError == ERROR_SUCCESS || dwError == ERROR_IO_PENDING {
          return true
        }
        SetLastError(dwError)
        return false
      }
      guard case let .bytes(bytes) = result else {
        throw OpenAPIWinHTTPError.headers
      }

      try Task.checkCancellation()
      return try lock.withLock {
        if let failure { throw failure }
        if bytes.isEmpty {
          if let length, received != length {
            throw OpenAPIWinHTTPError.length(expected: length, actual: received)
          }
          finish()
          return nil
        }
        let (count, overflow) =
            received.addingReportingOverflow(Int64(bytes.count))
        guard overflow == false else {
          throw OpenAPIWinHTTPError.framing("response is too large")
        }
        if let length, count > length {
          throw OpenAPIWinHTTPError.length(expected: length, actual: count)
        }
        received = count
        return bytes
      }
    } catch {
      close(error: error)
      throw error
    }
  }

  // MARK: - Callbacks

  private enum Completion: Sendable {
    case done
    case written(Int)
    case bytes(ArraySlice<UInt8>)
  }

  private func perform(_ dwInternetStatus: DWORD,
                       _ start: @Sendable (HINTERNET) -> Bool) async
      throws -> Completion {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        lock.withLock {
          if let failure { return continuation.resume(throwing: failure) }
          guard let hRequest else {
            return continuation.resume(throwing: CancellationError())
          }
          guard self.continuation == nil else {
            let error = OpenAPIWinHTTPError.concurrent
            return continuation.resume(throwing: error)
          }

          // Arm the completion before start can invoke an inline callback.
          self.dwInternetStatus = dwInternetStatus
          self.continuation = continuation
          if start(hRequest) == false {
            close(error: OpenAPIWinHTTPError.windows(code: GetLastError()))
          }
        }
      }
    } onCancel: {
      self.close(error: CancellationError())
    }
  }

  private func completed(_ dwInternetStatus: DWORD,
                         _ lpvStatusInformation: LPVOID?,
                         _ dwStatusInformationLength: DWORD) {
    lock.withLock {
      if dwInternetStatus == WINHTTP_CALLBACK_STATUS_REQUEST_ERROR {
        guard let lpvStatusInformation else { return }
        let result = lpvStatusInformation.load(as: WINHTTP_ASYNC_RESULT.self)
        return close(error: OpenAPIWinHTTPError.windows(code: result.dwError))
      }

      guard failure == nil, let continuation,
          dwInternetStatus == self.dwInternetStatus else {
        return
      }
      self.continuation = nil

      switch dwInternetStatus {
      case WINHTTP_CALLBACK_STATUS_WRITE_COMPLETE:
        guard let lpvStatusInformation else {
          let error =
              OpenAPIWinHTTPError.framing("missing write completion count")
          return continuation.resume(throwing: error)
        }
        let dwNumberOfBytesWritten = lpvStatusInformation.load(as: DWORD.self)
        let count = Int(dwNumberOfBytesWritten)
        continuation.resume(returning: .written(count))

      case WINHTTP_CALLBACK_STATUS_READ_COMPLETE:
        guard let lpBuffer,
            Int(dwStatusInformationLength) <= RequestContext.capacity else {
          return continuation.resume(throwing: OpenAPIWinHTTPError.headers)
        }
        let count = Int(dwStatusInformationLength)
        let bytes = Array(UnsafeRawBufferPointer(start: lpBuffer, count: count))
        continuation.resume(returning: .bytes(ArraySlice(bytes)))

      default:
        continuation.resume(returning: .done)
      }
    }
  }
}
