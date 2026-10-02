// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

package struct ResponseStream: AsyncSequence, Sendable {
  package typealias Element = ArraySlice<UInt8>
  private let owner: @Sendable () -> RequestContext

  package init(context: RequestContext) {
    let lifetime = Owner(context: context)
    // Closure copies share the noncopyable owner's cleanup lifetime.
    owner = { [lifetime] in
      lifetime.context
    }
  }

  package func makeAsyncIterator() -> Iterator {
    Iterator(stream: self)
  }

  package struct Iterator: AsyncIteratorProtocol {
    private let read: @Sendable () async throws -> Element?

    internal init(stream: ResponseStream) {
      let lease = Lease(owner: stream.owner)
      read = { [lease] in
        try await lease.context.read()
      }
    }

    package mutating func next() async throws -> Element? {
      try await read()
    }
  }

  private struct Owner: ~Copyable, Sendable {
    internal let context: RequestContext

    internal init(context: RequestContext) {
      self.context = context
    }

    deinit {
      context.close()
    }
  }

  private struct Lease: ~Copyable, Sendable {
    private let owner: @Sendable () -> RequestContext
    internal let context: RequestContext

    internal init(owner: @escaping @Sendable () -> RequestContext) {
      self.owner = owner
      context = owner()
    }

    deinit {
      withExtendedLifetime(owner) {
        context.close()
      }
    }
  }
}
