// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import WinSDK

@_transparent
internal var ERROR_INSUFFICIENT_BUFFER: DWORD {
  DWORD(WinSDK.ERROR_INSUFFICIENT_BUFFER)
}

@_transparent
internal var ERROR_INVALID_PARAMETER: DWORD {
  DWORD(WinSDK.ERROR_INVALID_PARAMETER)
}

@_transparent
internal var ERROR_IO_PENDING: DWORD {
  DWORD(WinSDK.ERROR_IO_PENDING)
}

@_transparent
internal var ERROR_SUCCESS: DWORD {
  DWORD(WinSDK.ERROR_SUCCESS)
}

@_transparent
internal var FORMAT_MESSAGE_FROM_SYSTEM: DWORD {
  DWORD(WinSDK.FORMAT_MESSAGE_FROM_SYSTEM)
}

@_transparent
internal var FORMAT_MESSAGE_IGNORE_INSERTS: DWORD {
  DWORD(WinSDK.FORMAT_MESSAGE_IGNORE_INSERTS)
}
