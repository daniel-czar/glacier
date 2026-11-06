import Foundation

/// Extracts explicit local destinations from inline Markdown links. This is
/// deliberately a small path recognizer, not a general Markdown renderer.
public enum MarkdownLocalLink {
    public struct Match {
        public let destination: String
        public let range: Range<Int>
    }

    public static func destinations(in text: String) -> [String] {
        matches(in: text).map(\.destination)
    }

    public static func remainingText(in text: String) -> String {
        let characters = Array(text)
        let matches = matches(in: text)
        guard !matches.isEmpty else { return text }
        var remaining = ""
        var cursor = 0
        for match in matches {
            remaining.append(contentsOf: characters[cursor..<match.range.lowerBound])
            remaining.append(" ")
            cursor = match.range.upperBound
        }
        remaining.append(contentsOf: characters[cursor...])
        return remaining
    }

    public static func matches(in text: String) -> [Match] {
        let characters = Array(text)
        var matches: [Match] = []
        var position = 0
        var openingBrackets: [Int] = []
        while position + 1 < characters.count {
            if characters[position] == "\\" {
                position += 2
                continue
            }
            if characters[position] == "[" {
                let start = position > 0 && characters[position - 1] == "!" ? position - 1 : position
                openingBrackets.append(start)
            }
            guard characters[position] == "]" else {
                position += 1
                continue
            }
            let start = openingBrackets.popLast()
            guard characters[position + 1] == "(", let start else {
                position += 1
                continue
            }
            var cursor = position + 2
            while cursor < characters.count, inlineSpace(characters[cursor]) { cursor += 1 }
            let destination: String
            if cursor < characters.count, characters[cursor] == "<" {
                cursor += 1
                var value = ""
                while cursor < characters.count, characters[cursor] != ">", !characters[cursor].isNewline {
                    value.append(characters[cursor])
                    cursor += 1
                }
                guard cursor < characters.count, characters[cursor] == ">" else {
                    position += 1
                    continue
                }
                destination = value
                cursor += 1
            } else {
                var value = ""
                var depth = 0
                while cursor < characters.count {
                    let character = characters[cursor]
                    if character.isWhitespace { break }
                    if character == "\\", cursor + 1 < characters.count {
                        cursor += 1
                        value.append(characters[cursor])
                    } else if character == "(" {
                        depth += 1
                        value.append(character)
                    } else if character == ")" {
                        if depth == 0 { break }
                        depth -= 1
                        value.append(character)
                    } else {
                        value.append(character)
                    }
                    cursor += 1
                }
                destination = value
            }
            while cursor < characters.count, inlineSpace(characters[cursor]) { cursor += 1 }
            if cursor < characters.count, (characters[cursor] == "\"" || characters[cursor] == "'") {
                let quote = characters[cursor]
                cursor += 1
                while cursor < characters.count, characters[cursor] != quote, !characters[cursor].isNewline {
                    if characters[cursor] == "\\" { cursor += 1 }
                    cursor += 1
                }
                guard cursor < characters.count, characters[cursor] == quote else { position += 1; continue }
                cursor += 1
                while cursor < characters.count, inlineSpace(characters[cursor]) { cursor += 1 }
            }
            if cursor < characters.count, characters[cursor] == ")",
               destination.hasPrefix("/") || destination.hasPrefix("~/") || destination.hasPrefix("file://") {
                matches.append(Match(destination: destination, range: start..<(cursor + 1)))
                position = cursor + 1
                openingBrackets.removeAll()
            } else {
                position += 1
            }
        }
        return matches
    }

    private static func inlineSpace(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

}
