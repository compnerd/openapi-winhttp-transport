// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// HTTP optional whitespace consists only of SP and HTAB (RFC 9110 §5.6.3).
package func whitespace(_ value: Substring) -> Substring {
  let leading = value.drop(while: { $0 == " " || $0 == "\t" })
  guard let end = leading.lastIndex(where: { $0 != " " && $0 != "\t" }) else {
    return leading[leading.endIndex...]
  }
  return leading[...end]
}
