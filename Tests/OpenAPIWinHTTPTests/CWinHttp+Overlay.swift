// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import CWinHTTP
internal import WinSDK

@_transparent
internal var INTERNET_DEFAULT_PORT: INTERNET_PORT {
  INTERNET_PORT(CWinHTTP.INTERNET_DEFAULT_PORT)
}

@_transparent
internal var WINHTTP_ACCESS_TYPE_NAMED_PROXY: DWORD {
  DWORD(CWinHTTP.WINHTTP_ACCESS_TYPE_NAMED_PROXY)
}

@_transparent
internal var WINHTTP_CALLBACK_FLAG_HANDLES: DWORD {
  DWORD(CWinHTTP.WINHTTP_CALLBACK_FLAG_HANDLES)
}

@_transparent
internal var WINHTTP_FLAG_ASYNC: DWORD {
  DWORD(CWinHTTP.WINHTTP_FLAG_ASYNC)
}

@_transparent
internal var WINHTTP_IGNORE_REQUEST_TOTAL_LENGTH: DWORD {
  DWORD(CWinHTTP.WINHTTP_IGNORE_REQUEST_TOTAL_LENGTH)
}

@_transparent
internal var WINHTTP_NO_PROXY_BYPASS: LPCWSTR? {
  nil
}

@_transparent
internal var WINHTTP_PROTOCOL_FLAG_HTTP2: DWORD {
  DWORD(CWinHTTP.WINHTTP_PROTOCOL_FLAG_HTTP2)
}

@_transparent
internal var WINHTTP_PROTOCOL_FLAG_HTTP3: DWORD {
  DWORD(CWinHTTP.WINHTTP_PROTOCOL_FLAG_HTTP3)
}

// This sentinel is an address, never a callable Swift function value.
@_transparent
internal var WINHTTP_INVALID_STATUS_CALLBACK: UnsafeRawPointer? {
  UnsafeRawPointer(bitPattern: -1)
}
