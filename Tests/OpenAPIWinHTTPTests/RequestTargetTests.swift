// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import struct FoundationEssentials.URL
internal import HTTPTypes
internal import Testing
internal import OpenAPIWinHTTPTransport

internal struct RequestTargetTests {
  @Test(arguments: [
    ("http://example.com", "/pets", "/pets"),
    ("http://example.com/api", "/pets", "/api/pets"),
    ("http://example.com/api/", "/pets", "/api/pets"),
    ("http://example.com/api", "pets", "/api/pets"),
    ("http://example.com", "", "/"),
    ("http://example.com/api", "", "/api"),
    ("http://example.com/api?ignored=yes#fragment", "/pets?limit=10",
     "/api/pets?limit=10"),
    ("http://example.com/a%2Fb", "/c%2Fd?q=x%2Fy&name=a%20b",
     "/a%2Fb/c%2Fd?q=x%2Fy&name=a%20b"),
    ("http://example.com/api", "?limit=10", "/api?limit=10"),
    ("http://example.com", "/pets?", "/pets?"),
    ("http://example.com?ignored=yes#fragment", "/pets", "/pets"),
    ("http://example.com/a%2Fb", "/caf%C3%A9?q=x%3Fy%23z",
     "/a%2Fb/caf%C3%A9?q=x%3Fy%23z"),
    ("http://example.com/api/", "", "/api/"),
    ("http://example.com", "?limit=10", "/?limit=10"),
    ("http://example.com", "/café?q=a b", "/caf%C3%A9?q=a%20b"),
  ])
  internal func composition(base: String, path: String,
                            expected: String) throws {
    let url = try #require(URL(string: base))
    let request =
        HTTPRequest(method: .get, scheme: nil, authority: nil, path: path)
    let target = try WinHttpTarget(request: request, url: url)
    #expect(target.path == expected)
    #expect(target.host == "example.com")
  }

  @Test
  internal func unspecified() throws {
    let url = try #require(URL(string: "http://example.com/api"))
    let request =
        HTTPRequest(method: .get, scheme: nil, authority: nil, path: nil)
    let target = try WinHttpTarget(request: request, url: url)
    #expect(target.path == "/api")
  }

  @Test(arguments: [
    ("http://%65xample.com", "example.com"),
    ("https://xn--mnich-kva.example", "xn--mnich-kva.example"),
  ])
  internal func hosts(base: String, expected: String) throws {
    let url = try #require(URL(string: base))
    let request =
        HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/")
    let target = try WinHttpTarget(request: request, url: url)
    #expect(target.host == expected)
  }

  @Test(arguments: [
    ("http://example.com", Int(INTERNET_DEFAULT_PORT), false),
    ("https://example.com", Int(INTERNET_DEFAULT_PORT), true),
    ("HTTPS://example.com", Int(INTERNET_DEFAULT_PORT), true),
    ("http://example.com:8080", 8080, false),
    ("https://example.com:8443", 8443, true),
  ])
  internal func security(base: String, port: Int, secure: Bool) throws {
    let url = try #require(URL(string: base))
    let request =
        HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/")
    let target = try WinHttpTarget(request: request, url: url)
    #expect(Int(target.port) == port)
    #expect(target.secure == secure)
  }

  @Test(arguments: [
    "ftp://example.com", "file:///tmp/api", "/api",
    "http://example.com:0", "http://example.com:65536",
  ])
  internal func base(base: String) throws {
    let url = try #require(URL(string: base))
    #expect(throws: (any Error).self) {
      let request =
          HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/pets")
      _ = try WinHttpTarget(request: request, url: url)
    }
  }

  @Test(arguments: [
    "https://other.example/pets", "//other.example/pets", "/pets#fragment",
  ])
  internal func paths(path: String) throws {
    let url = try #require(URL(string: "https://example.com/api"))
    #expect(throws: (any Error).self) {
      let request =
          HTTPRequest(method: .get, scheme: nil, authority: nil, path: path)
      _ = try WinHttpTarget(request: request, url: url)
    }
  }
}
