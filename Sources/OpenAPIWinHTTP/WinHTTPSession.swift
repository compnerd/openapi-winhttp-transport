// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

private import WinSDK
@_implementationOnly
internal import CWinHTTP

@_implementationOnly
internal struct WinHTTPSession: ~Copyable, @unchecked Sendable {
  private static let shared = Result(catching: WinHTTPSession.init)
  internal let hSession: HINTERNET

  internal static func get() throws(OpenAPIWinHTTPError) -> HINTERNET {
    return switch shared {
    case let .success(session):
      session.hSession
    case let .failure(error):
      throw error
    }
  }

  internal init() throws(OpenAPIWinHTTPError) {
    guard let hSession =
        WinHttpOpen(nil, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                    WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS,
                    WINHTTP_FLAG_ASYNC) else {
      throw .windows(code: GetLastError())
    }
    do throws(OpenAPIWinHTTPError) {
      var dwProtocols = WINHTTP_PROTOCOL_FLAG_HTTP2
                      | WINHTTP_PROTOCOL_FLAG_HTTP3
      let dwBufferLength = DWORD(MemoryLayout.size(ofValue: dwProtocols))
      if WinHttpSetOption(hSession, WINHTTP_OPTION_ENABLE_HTTP_PROTOCOL,
                          &dwProtocols, dwBufferLength) == false {
        let dwError = GetLastError()
        guard dwError == ERROR_INVALID_PARAMETER ||
            dwError == ERROR_WINHTTP_INVALID_OPTION else {
          throw .windows(code: dwError)
        }
        dwProtocols = WINHTTP_PROTOCOL_FLAG_HTTP2
        guard WinHttpSetOption(hSession, WINHTTP_OPTION_ENABLE_HTTP_PROTOCOL,
                               &dwProtocols, dwBufferLength) else {
          throw .windows(code: GetLastError())
        }
      }

      var dwDecompressionFlags = WINHTTP_DECOMPRESSION_FLAG_GZIP
      guard WinHttpSetOption(hSession, WINHTTP_OPTION_DECOMPRESSION,
                             &dwDecompressionFlags,
                             DWORD(MemoryLayout<DWORD>.size)) else {
        throw .windows(code: GetLastError())
      }
    } catch {
      _ = WinHttpCloseHandle(hSession)
      throw error
    }
    self.hSession = hSession
  }

  deinit {
    _ = WinHttpCloseHandle(hSession)
  }
}
