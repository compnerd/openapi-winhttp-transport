// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

@_implementationOnly
private import CWinHTTP
package import FoundationEssentials
package import HTTPTypes

package enum InvalidRequest: Error {
  case base(URL)
  case path(String)
}

package struct WinHttpTarget {
  package let host: String
  package let port: UInt16
  package let path: String
  package let secure: Bool

  package init(request: borrowing HTTPRequest, url: URL)
      throws(InvalidRequest) {
    guard let port = UInt16(exactly: url.port ?? Int(INTERNET_DEFAULT_PORT)),
        url.port == nil || port > 0 else {
      throw .base(url)
    }

    // WinHTTP requires a slash before a query on an otherwise empty path.
    let address = url.path(percentEncoded: true).isEmpty
                      ? url.appendingPathComponent("").absoluteString
                      : url.absoluteString
    let (hostname, resource, secure) =
        try address.withCString(encodedAs: UTF16.self,
                                { pwszUrl throws(InvalidRequest) in
          var native = URL_COMPONENTS()
          native.dwStructSize = DWORD(MemoryLayout<URL_COMPONENTS>.size)
          native.dwSchemeLength = DWORD(bitPattern: -1)
          native.dwHostNameLength = DWORD(bitPattern: -1)
          native.dwUrlPathLength = DWORD(bitPattern: -1)
          native.dwExtraInfoLength = DWORD(bitPattern: -1)
          guard WinHttpCrackUrl(pwszUrl, 0, 0, &native),
              native.dwHostNameLength > 0 else {
            throw .base(url)
          }
          let secure = switch native.nScheme {
          case INTERNET_SCHEME_HTTP: false
          case INTERNET_SCHEME_HTTPS: true
          default: throw InvalidRequest.base(url)
          }
          let hostname =
              UnsafeBufferPointer(start: native.lpszHostName,
                                  count: Int(native.dwHostNameLength))
          let resource =
              UnsafeBufferPointer(start: native.lpszUrlPath,
                                  count: Int(native.dwUrlPathLength))
          guard let host = String(decoding: hostname, as: UTF16.self)
              .removingPercentEncoding, !host.isEmpty else {
            throw .base(url)
          }
          return (host, String(decoding: resource, as: UTF16.self), secure)
        })

    var path = resource.isEmpty ? "/" : resource
    if let location = request.path, !location.isEmpty {
      guard let operation = URL(string: location),
          operation.scheme == nil, operation.host == nil,
          operation.fragment == nil else {
        throw .path(location)
      }
      let suffix = operation.path(percentEncoded: true)
      if suffix.isEmpty == false {
        switch (path.hasSuffix("/"), suffix.hasPrefix("/")) {
        case (true, true):
          path.removeLast()
        case (false, false):
          path += "/"
        default:
          break
        }
        path += suffix
      }
      if let query = operation.query(percentEncoded: true) {
        path += "?" + query
      }
    }

    self.host = hostname
    self.port = port
    self.path = path
    self.secure = secure
  }
}
