import Foundation

/// Protects the parser from a known pathological input.
///
/// SwiftSyntax's speculative type parsing is exponential in the length of a run of directly nested
/// square brackets (`[[[[1]]]]` or `[[[[Int]]]]`): 16 levels take seconds, 20 take minutes. Runs longer
/// than `maximumSquareRun` have their excess brackets (and the matching closers) replaced by spaces.
/// Byte offsets and newlines are preserved, so every reported line and column stays exact, and the code
/// inside the brackets is still analysed. Brackets inside strings and comments are left alone.
enum SwiftSourceGuard {
    static let maximumSquareRun = 10

    private static let openSquare = UInt8(ascii: "[")
    private static let closeSquare = UInt8(ascii: "]")
    private static let openParen = UInt8(ascii: "(")
    private static let closeParen = UInt8(ascii: ")")
    private static let quote = UInt8(ascii: "\"")
    private static let hash = UInt8(ascii: "#")
    private static let slash = UInt8(ascii: "/")
    private static let star = UInt8(ascii: "*")
    private static let backslash = UInt8(ascii: "\\")
    private static let newline = UInt8(ascii: "\n")
    private static let space = UInt8(ascii: " ")

    /// Returns a defused copy of the source, or nil when it contains no excessive bracket run.
    static func defuse(_ bytes: [UInt8]) -> [UInt8]? {
        guard longestBracketRun(bytes) > maximumSquareRun else { return nil }
        return lexicalDefuse(bytes)
    }

    /// Upper bound on the longest run of `[` separated only by whitespace (ignores strings/comments).
    static func longestBracketRun(_ bytes: [UInt8]) -> Int {
        var longest = 0
        var run = 0
        for byte in bytes {
            switch byte {
            case openSquare:
                run += 1
                if run > longest { longest = run }
            case 0x20, 0x09, 0x0A, 0x0D:
                continue
            default:
                run = 0
            }
        }
        return longest
    }

    private enum Mode {
        /// Code; `parens` counts open parentheses inside a string interpolation (nil at top level).
        case code(parens: Int?)
        case string(multiline: Bool, hashes: Int)
        case lineComment
        case blockComment(depth: Int)
    }

    static func lexicalDefuse(_ input: [UInt8]) -> [UInt8] {
        var bytes = input
        let count = bytes.count
        var modes: [Mode] = [.code(parens: nil)]
        var openBrackets: [(offset: Int, isExcess: Bool)] = []
        var blank: [Int] = []
        var run = 0
        var index = 0

        func byte(_ offset: Int) -> UInt8? { offset < count ? bytes[offset] : nil }

        while index < count {
            let current = bytes[index]
            switch modes[modes.count - 1] {
            case .lineComment:
                if current == newline { modes.removeLast() }
                index += 1

            case .blockComment(let depth):
                if current == star, byte(index + 1) == slash {
                    if depth == 1 { modes.removeLast() } else { modes[modes.count - 1] = .blockComment(depth: depth - 1) }
                    index += 2
                } else if current == slash, byte(index + 1) == star {
                    modes[modes.count - 1] = .blockComment(depth: depth + 1)
                    index += 2
                } else {
                    index += 1
                }

            case .string(let multiline, let hashes):
                if current == backslash {
                    var cursor = index + 1
                    var seen = 0
                    while seen < hashes, byte(cursor) == hash {
                        seen += 1
                        cursor += 1
                    }
                    if seen == hashes {
                        if byte(cursor) == openParen {
                            modes.append(.code(parens: 1))
                            run = 0
                            index = cursor + 1
                        } else {
                            index = cursor + 1   // skip the escaped character
                        }
                    } else {
                        index += 1
                    }
                } else if current == quote {
                    var cursor = index + 1
                    if multiline {
                        guard byte(index + 1) == quote, byte(index + 2) == quote else {
                            index += 1
                            continue
                        }
                        cursor = index + 3
                    }
                    var seen = 0
                    while seen < hashes, byte(cursor) == hash {
                        seen += 1
                        cursor += 1
                    }
                    if seen == hashes {
                        modes.removeLast()
                        index = cursor
                    } else {
                        index += 1
                    }
                } else if current == newline, !multiline {
                    modes.removeLast()   // unterminated single-line string
                    index += 1
                } else {
                    index += 1
                }

            case .code(let parens):
                if current == slash, byte(index + 1) == slash {
                    modes.append(.lineComment)
                    run = 0
                    index += 2
                    continue
                }
                if current == slash, byte(index + 1) == star {
                    modes.append(.blockComment(depth: 1))
                    run = 0
                    index += 2
                    continue
                }
                if current == hash || current == quote {
                    var cursor = index
                    var hashes = 0
                    while byte(cursor) == hash {
                        hashes += 1
                        cursor += 1
                    }
                    if byte(cursor) == quote {
                        let multiline = byte(cursor + 1) == quote && byte(cursor + 2) == quote
                        modes.append(.string(multiline: multiline, hashes: hashes))
                        run = 0
                        index = cursor + (multiline ? 3 : 1)
                        continue
                    }
                }
                switch current {
                case openSquare:
                    run += 1
                    openBrackets.append((index, run > maximumSquareRun))
                case closeSquare:
                    run = 0
                    if let open = openBrackets.popLast(), open.isExcess {
                        blank.append(open.offset)
                        blank.append(index)
                    }
                case 0x20, 0x09, 0x0A, 0x0D:
                    break
                case openParen:
                    run = 0
                    if let parens { modes[modes.count - 1] = .code(parens: parens + 1) }
                case closeParen:
                    run = 0
                    if let parens {
                        if parens == 1 { modes.removeLast() } else { modes[modes.count - 1] = .code(parens: parens - 1) }
                    }
                default:
                    run = 0
                }
                index += 1
            }
        }
        for open in openBrackets where open.isExcess {
            blank.append(open.offset)
        }
        for offset in blank {
            bytes[offset] = space
        }
        return bytes
    }
}
