// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import HTTPTypes

extension HTTPFields {
  internal func length() throws(OpenAPIWinHTTPError) -> Int64? {
    var length: Int64?
    let digits = UInt8(ascii: "0") ... UInt8(ascii: "9")
    for value in self[values: .contentLength] {
      for component in value.split(separator: ",",
                                   omittingEmptySubsequences: false) {
        let text = whitespace(component)
        guard !text.isEmpty, text.utf8.allSatisfy(digits.contains),
            let parsed = Int64(text), length == nil || length == parsed else {
          throw .framing("invalid or conflicting Content-Length")
        }
        length = parsed
      }
    }
    return length
  }
}
