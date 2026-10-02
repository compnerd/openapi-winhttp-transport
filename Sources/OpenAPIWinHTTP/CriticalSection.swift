// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

private import WinSDK

// WinHTTP may call back before an API returns. Recursive locking also prevents
// cancellation from closing a handle while another thread uses a WinHTTP API.
internal struct CriticalSection: ~Copyable, @unchecked Sendable {
  private let storage: UniqueBox<CRITICAL_SECTION>
  private let lpCriticalSection: UnsafeMutablePointer<CRITICAL_SECTION>

  internal init() {
    var storage = UniqueBox(CRITICAL_SECTION())
    // UniqueBox keeps this address stable across moves of the lock owner.
    lpCriticalSection =
        withUnsafeMutablePointer(to: &storage.value) { lpCriticalSection in
          InitializeCriticalSection(lpCriticalSection)
          return lpCriticalSection
        }
    self.storage = consume storage
  }

  deinit {
    DeleteCriticalSection(lpCriticalSection)
  }

  internal func withLock<Result, Failure>(_ body: () throws(Failure) -> Result)
      throws(Failure) -> Result where Failure: Error {
    try withExtendedLifetime(storage) { () throws(Failure) in
      EnterCriticalSection(lpCriticalSection)
      defer {
        LeaveCriticalSection(lpCriticalSection)
      }
      return try body()
    }
  }
}
