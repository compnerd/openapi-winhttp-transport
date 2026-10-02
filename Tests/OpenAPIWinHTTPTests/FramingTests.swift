// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import HTTPTypes
internal import OpenAPIRuntime
internal import Testing
internal import OpenAPIWinHTTPTransport

internal struct FramingTests {
  @Test("Native headers widen Latin-1 bytes without interpreting UTF-8")
  internal func headers() throws(any Error) {
    let name = try #require(HTTPField.Name("X-Value"))
    // These include UTF-8-looking sequences, C1 bytes rejected by WinHTTP,
    // and the full upper Latin-1 range. The transport preserves all of them.
    let bytes = Array(UInt8(0x80) ... UInt8(0xff))
    var fields = HTTPFields()
    fields.append(HTTPField(name: name, value: bytes))
    fields.append(HTTPField(name: name, value: Array("second".utf8)))
    let upload = try UploadRequest(fields: fields, length: nil)
    let prefix = Array("X-Value: ".utf16)
    let suffix = Array("\r\nX-Value: second\r\n".utf16)
    let expected = prefix + bytes.map(UInt16.init) + suffix
    #expect(upload.headers == expected)
    #expect(try UploadRequest(fields: [:], length: nil).headers.isEmpty)
  }

  @Test(arguments: [Int64(0), 1, 65536, Int64(UInt32.max),
                    Int64(UInt32.max) + 1,])
  internal func known(length: Int64) throws(OpenAPIWinHTTPError) {
    let upload = try UploadRequest(fields: [:], length: .known(length))
    #expect(upload.streaming == false)
    #expect(upload.expected == length)
    let total = UInt32(exactly: length) ?? WINHTTP_IGNORE_REQUEST_TOTAL_LENGTH
    #expect(upload.total == total)
    let headers = String(decoding: upload.headers, as: UTF16.self)
    #expect(headers.contains("Content-Length: \(length)\r\n"))
  }

  @Test
  internal func chunking() throws(OpenAPIWinHTTPError) {
    let upload = try UploadRequest(fields: [:], length: .unknown)
    #expect(upload.streaming)
    #expect(upload.expected == nil)
    #expect(upload.total == WINHTTP_IGNORE_REQUEST_TOTAL_LENGTH)
    let headers = String(decoding: upload.headers, as: UTF16.self)
    #expect(headers.contains("Transfer-Encoding") == false)
    #expect(headers.contains("Content-Length") == false)
  }

  @Test
  internal func declared() throws(OpenAPIWinHTTPError) {
    let upload =
        try UploadRequest(fields: [.contentLength: "42"], length: .unknown)
    #expect(upload.streaming == false)
    #expect(upload.expected == 42)
    #expect(upload.total == 42)
  }

  @Test
  internal func explicit() throws(OpenAPIWinHTTPError) {
    let upload =
        try UploadRequest(fields: [.transferEncoding: "chunked"],
                          length: .known(42))
    #expect(upload.streaming)
    #expect(upload.expected == 42)
    let headers = String(decoding: upload.headers, as: UTF16.self)
    #expect(headers.contains("Content-Length") == false)
  }

  @Test(arguments: ["-1", "+1", "1 0", "1,2", "", "18446744073709551616"])
  internal func invalid(value: String) {
    #expect(throws: OpenAPIWinHTTPError.self) {
      try UploadRequest(fields: [.contentLength: value], length: .unknown)
    }
  }

  @Test
  internal func duplicates() throws(OpenAPIWinHTTPError) {
    var fields: HTTPFields = [.contentLength: "42"]
    fields.append(HTTPField(name: .contentLength, value: "42, 42"))
    let upload = try UploadRequest(fields: fields, length: .known(42))
    let headers = String(decoding: upload.headers, as: UTF16.self)
    #expect(headers == "Content-Length: 42\r\n")
  }

  @Test
  internal func contradictions() {
    #expect(throws: OpenAPIWinHTTPError.self) {
      try UploadRequest(fields: [.contentLength: "42",
                                 .transferEncoding: "chunked"],
                        length: .known(42))
    }
    #expect(throws: OpenAPIWinHTTPError.self) {
      try UploadRequest(fields: [.contentLength: "42"], length: .known(41))
    }
    #expect(throws: OpenAPIWinHTTPError.self) {
      try UploadRequest(fields: [.contentLength: "42"], length: nil)
    }
    #expect(throws: OpenAPIWinHTTPError.self) {
      try UploadRequest(fields: [:], length: .known(-1))
    }
  }

  @Test(arguments: ["gzip", "gzip, chunked", "chunked, chunked"])
  internal func encoding(value: String) {
    #expect(throws: OpenAPIWinHTTPError.self) {
      try UploadRequest(fields: [.transferEncoding: value], length: .unknown)
    }
  }

  @Test
  internal func length() throws(OpenAPIWinHTTPError) {
    var response =
        HTTPResponse(status: .ok, headerFields: [.contentLength: "42"])
    #expect(try response.length() == .known(42))
    response.headerFields[.transferEncoding] = "chunked"
    #expect(try response.length() == .unknown)
  }
}
