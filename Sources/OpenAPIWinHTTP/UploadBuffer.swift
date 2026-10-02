// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

private import Synchronization

/// A single producer and consumer overlap body iteration with native writes.
/// Drain whatever is ready immediately; never wait to fill a batch.
/// Backpressure limits queued bytes to one I/O buffer, and slices retain the
/// producer's bytes.
package struct UploadBuffer: ~Copyable, Sendable {
  private typealias Reader = CheckedContinuation<Batch?, any Error>
  private typealias Writer = CheckedContinuation<Void, any Error>

  package struct Batch: Sendable {
    package let chunks: Array<ArraySlice<UInt8>>
    package let count: Int
  }

  private struct State: Sendable {
    internal var chunks = Array<ArraySlice<UInt8>>()
    internal var count = 0
    internal var reader: Reader?
    internal var writer: (chunk: ArraySlice<UInt8>, continuation: Writer)?
    internal var ended = false
    internal var failure: (any Error)?
  }

  private let state = Mutex(State())

  package init() {
  }

#if WORKAROUND_SWIFT_87573
  // FIXME(https://github.com/swiftlang/swift/issues/87573)
  // Keep private Mutex state destruction in this file to avoid Swift's
  // cross-file metadata linkage bug in unoptimized builds.
  deinit {
  }
#endif

  package func append(_ chunk: ArraySlice<UInt8>) async throws(any Error) {
    precondition(chunk.isEmpty == false &&
                 chunk.count <= RequestContext.capacity)
    try Task.checkCancellation()
    try await withCheckedThrowingContinuation { (continuation: Writer) in
      state.withLock { state in
        if let failure = state.failure {
          return continuation.resume(throwing: failure)
        }
        precondition(state.ended == false && state.writer == nil)
        if state.count + chunk.count > RequestContext.capacity {
          state.writer = (chunk, continuation)
          return
        }
        if let reader = state.reader {
          state.reader = nil
          reader.resume(returning: Batch(chunks: [chunk], count: chunk.count))
        } else {
          state.chunks.append(chunk)
          state.count += chunk.count
        }
        continuation.resume()
      }
    }
  }

  package func next() async throws(any Error) -> Batch? {
    try Task.checkCancellation()
    return try await withCheckedThrowingContinuation { (continuation: Reader) in
      state.withLock { state in
        if let failure = state.failure {
          return continuation.resume(throwing: failure)
        }
        precondition(state.reader == nil)
        if state.count > 0 {
          let batch = Batch(chunks: state.chunks, count: state.count)
          // Admit the waiting chunk atomically with draining the queue. No
          // producer state is read or modified across an async suspension.
          if let writer = state.writer {
            state.writer = nil
            state.chunks = [writer.chunk]
            state.count = writer.chunk.count
            writer.continuation.resume()
          } else {
            state.chunks = []
            state.count = 0
          }
          return continuation.resume(returning: batch)
        }
        if state.ended { return continuation.resume(returning: nil) }
        state.reader = continuation
      }
    }
  }

  package func finish(error: (any Error)? = nil) {
    state.withLock { state in
      if let error, state.failure == nil { state.failure = error }
      state.ended = true
      let reader = state.reader
      let writer = state.writer
      state.reader = nil
      state.writer = nil
      if let failure = state.failure {
        state.chunks = []
        state.count = 0
        reader?.resume(throwing: failure)
        writer?.continuation.resume(throwing: failure)
      } else {
        reader?.resume(returning: nil)
      }
    }
  }
}
