# OpenAPI WinHTTP Transport

A Windows transport for Swift OpenAPI Runtime using asynchronous WinHTTP.
Requires Swift 6.4 or newer and Windows 11 or Windows Server 2022 or newer.

## Usage

Add the package to your application's dependencies:

```swift
.package(url: "https://github.com/compnerd/openapi-winhttp-transport",
         branch: "main")
```

Add its product to your target's dependencies:

```swift
.product(name: "OpenAPIWinHTTPTransport", package: "openapi-winhttp-transport")
```

Pass a `WinHttpTransport` to your generated client's `transport` parameter:

```swift
import OpenAPIWinHTTPTransport

let transport = WinHttpTransport()
```

## Behavior

All instances share a lazily opened WinHTTP session and connection pool.
Concurrent requests have independent handles and buffers. Session creation
failures are cached.

Requests use the supplied method, join encoded server and operation paths, and
preserve queries and repeated header fields and their bytes. WinHTTP may reject
header values containing C1 control characters. HTTPS follows Windows
certificate validation and TLS policy.
WinHTTP negotiates HTTP/2 and HTTP/3 with HTTP/1.1 fallback; if HTTP/3 is
unsupported, the session enables HTTP/2 instead.

Uploads stream incrementally with validated lengths and framing. Unknown-length
uploads use native protocol framing unless a `Content-Length` is supplied.
For large or unknown-length bodies, body iteration overlaps native writes with
at most 64 KiB of queued chunks. Each write drains whatever is ready, without
waiting for a full buffer. Small known-length bodies use the direct write path.
Explicit `Transfer-Encoding: chunked` selects native streaming; the transport
omits that header to allow HTTP/2 and HTTP/3. Uploads finish before response
headers are read, so early server rejections may wait for the producer or
surface as native write errors.

Responses are returned after their headers arrive; bodies are read on demand.
Chunks own their bytes. Finishing or abandoning an iterator, or releasing an
unused body, closes the request. Read failures and truncation throw during
iteration.

WinHTTP advertises and incrementally decodes gzip, managing `Accept-Encoding`.
Decoded responses omit `Content-Encoding` and the encoded `Content-Length`;
their body length is unknown. Other encodings, including deflate, pass through
unchanged.

Cancelling the task sending a request or reading its body closes the request
and throws `CancellationError`. Suspended upload producers must cooperate with
task cancellation. WinHTTP's default timeouts apply.

Redirects and authentication challenges are returned to the caller. Requests
are not retried or replayed. Automatic authentication and session cookies are
disabled; explicit authorization and cookie headers are forwarded.

## Testing

Run `swift test` on Windows. Set `WINHTTP_TEST_URL` to enable network tests.
Start the fixture in a separate terminal with Python 3:

```text
python Tests/Fixtures/server.py
```

Then, in PowerShell:

```powershell
$env:WINHTTP_TEST_URL = 'http://127.0.0.1:18841'
swift test
```

Unit tests cover URL composition and body framing. The HTTP fixture covers
streaming, compression, cancellation, failures, headers, authentication,
redirects and session reuse. CI runs these tests on Windows ARM64 and x64.

With `WINHTTP_TEST_URL` set, these optional checks are also available:

| Environment variable | Check |
| --- | --- |
| `WINHTTP_TEST_TLS_URL` | HTTPS server with an untrusted certificate |
| `WINHTTP_TEST_TRUSTED_URL` | HTTPS server with a trusted certificate |
| `WINHTTP_TEST_HTTP2_URL` | HTTP/2 uploads at `https://nghttp2.org` |
| `WINHTTP_TEST_PROTOCOL_URL` | HTTP/3 at `https://www.cloudflare.com` |

The external protocol checks use `/httpbin/post` and `/cdn-cgi/trace`,
respectively. HTTP/3 requires outbound UDP port 443.

### Local HTTP/2 and HTTP/3 tests

Start the optional protocol fixture:

```text
python -m pip install aioquic h2
python Tests/Fixtures/protocols.py
```

Then, in a separate PowerShell terminal:

```powershell
$env:WINHTTP_TEST_MULTIPLEX_URL = 'https://localhost:18849'
$env:WINHTTP_TEST_PROXY = '127.0.0.1:18851'
swift test
```

These Debug tests cover protocol negotiation, uploads, streaming, cancellation,
multiplexing and CONNECT proxy routing. The fixture serves TLS/TCP and QUIC/UDP
on port 18849 and a proxy on port 18851. It generates an ephemeral localhost
certificate; fixture requests allow that issuer while retaining hostname and
expiry checks. Windows trust settings and production validation are unchanged.

Licensed under BSD-3-Clause; see [LICENSE](LICENSE).
