// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

package import HTTPTypes
package import OpenAPIRuntime

extension HTTPResponse {
  package func length() throws(OpenAPIWinHTTPError) -> HTTPBody.Length {
    guard headerFields[.transferEncoding] == nil,
        let count = try headerFields.length() else {
      return .unknown
    }
    return .known(count)
  }
}
