import Foundation

enum SwiftSourceLexicalMasker {
  static func codeOnly(_ source: String) -> String {
    var masker = Masker(bytes: Array(source.utf8))
    return masker.codeOnly()
  }

  private struct Masker {
    let bytes: [UInt8]
    var output: [UInt8]

    init(bytes: [UInt8]) {
      self.bytes = bytes
      output = bytes
    }

    mutating func codeOnly() -> String {
      _ = scanCode(from: 0, interpolationDepth: nil)
      return String(decoding: output, as: UTF8.self)
    }

    private mutating func scanCode(from start: Int, interpolationDepth: Int?) -> Int {
      var index = start
      var depth = interpolationDepth
      while index < bytes.count {
        if starts(with: [0x2F, 0x2F], at: index) {
          let commentStart = index
          index += 2
          while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D {
            index += 1
          }
          mask(commentStart..<index)
          continue
        }

        if starts(with: [0x2F, 0x2A], at: index) {
          let commentStart = index
          index += 2
          var commentDepth = 1
          while index < bytes.count, commentDepth > 0 {
            if starts(with: [0x2F, 0x2A], at: index) {
              commentDepth += 1
              index += 2
            } else if starts(with: [0x2A, 0x2F], at: index) {
              commentDepth -= 1
              index += 2
            } else {
              index += 1
            }
          }
          mask(commentStart..<index)
          continue
        }

        let rawHashCount = consecutiveByteCount(0x23, at: index)
        let quoteIndex = index + rawHashCount
        if quoteIndex < bytes.count, bytes[quoteIndex] == 0x22 {
          index = scanString(from: index, quoteIndex: quoteIndex, rawHashCount: rawHashCount)
          continue
        }

        if let currentDepth = depth {
          if bytes[index] == 0x28 {
            depth = currentDepth + 1
          } else if bytes[index] == 0x29 {
            let nextDepth = currentDepth - 1
            index += 1
            if nextDepth == 0 {
              return index
            }
            depth = nextDepth
            continue
          }
        }
        index += 1
      }
      return index
    }

    private mutating func scanString(
      from start: Int,
      quoteIndex: Int,
      rawHashCount: Int
    ) -> Int {
      let isMultiline = starts(with: [0x22, 0x22, 0x22], at: quoteIndex)
      let quoteCount = isMultiline ? 3 : 1
      let closingDelimiter =
        Array(repeating: UInt8(0x22), count: quoteCount)
        + Array(repeating: UInt8(0x23), count: rawHashCount)
      let interpolationMarker =
        [UInt8(0x5C)]
        + Array(repeating: UInt8(0x23), count: rawHashCount) + [UInt8(0x28)]
      var literalStart = start
      var index = quoteIndex + quoteCount

      while index < bytes.count {
        if starts(with: closingDelimiter, at: index) {
          let end = index + closingDelimiter.count
          mask(literalStart..<end)
          return end
        }
        if starts(with: interpolationMarker, at: index) {
          let expressionStart = index + interpolationMarker.count
          mask(literalStart..<expressionStart)
          index = scanCode(from: expressionStart, interpolationDepth: 1)
          literalStart = index
          continue
        }
        if rawHashCount == 0, bytes[index] == 0x5C {
          index = min(index + 2, bytes.count)
        } else {
          index += 1
        }
      }

      mask(literalStart..<index)
      return index
    }

    private mutating func mask(_ range: Range<Int>) {
      for position in range where bytes[position] != 0x0A && bytes[position] != 0x0D {
        output[position] = 0x20
      }
    }

    private func starts(with needle: [UInt8], at index: Int) -> Bool {
      guard index >= 0, index + needle.count <= bytes.count else { return false }
      return bytes[index..<(index + needle.count)].elementsEqual(needle)
    }

    private func consecutiveByteCount(_ byte: UInt8, at index: Int) -> Int {
      var count = 0
      while index + count < bytes.count, bytes[index + count] == byte {
        count += 1
      }
      return count
    }
  }
}
