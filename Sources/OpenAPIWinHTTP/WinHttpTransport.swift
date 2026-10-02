// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import FoundationEssentials
public import HTTPTypes
public import OpenAPIRuntime

public struct WinHttpTransport: ClientTransport {
  /// Creates a transport. All transports share a lazily opened WinHTTP session.
  public init() {
  }

  public func send(_ request: HTTPRequest, body: HTTPBody?, baseURL url: URL,
                   operationID operation: String) async throws
      -> (HTTPResponse, HTTPBody?) {
    try Task.checkCancellation()
    let target = try WinHttpTarget(request: request, url: url)
    let upload =
        try UploadRequest(fields: request.headerFields, length: body?.length)
    let context =
        try RequestContext(method: request.method, target: target,
                            streaming: upload.streaming)

    return try await withTaskCancellationHandler {
      do {
        try await context.send(upload.headers, total: upload.total)
        try await upload.send(body, to: context)
        try await context.receive()
        let response = try context.response()
        try Task.checkCancellation()

        if request.method == .head || response.status == .noContent ||
            response.status == .notModified {
          context.finish()
          return (response, nil)
        }

        let length = try response.length()
        context.expect(length)
        let body = HTTPBody(ResponseStream(context: context), length: length,
                            iterationBehavior: .single)
        return (response, body)
      } catch {
        context.close(error: error)
        throw error
      }
    } onCancel: {
      context.close(error: CancellationError())
    }
  }
}
