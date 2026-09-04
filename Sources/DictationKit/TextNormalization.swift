import Foundation

public struct DeterministicTextNormalizer: TextNormalizer {
    public init() {}

    public func normalize(_ text: String) -> String {
        TimeFormatting.format(DateFormatting.format(text))
    }
}

public enum DateFormatting {
    private struct Token {
        let raw: String
        let start: String.Index
        let end: String.Index
    }

    private struct NumberMatch {
        let value: Int
        let length: Int
    }

    private static let months: [String: String] = [
        "january": "January", "february": "February", "march": "March",
        "april": "April", "may": "May", "june": "June", "july": "July",
        "august": "August", "september": "September", "october": "October",
        "november": "November", "december": "December",
    ]

    private static let small: [String: Int] = [
        "one": 1, "first": 1, "two": 2, "second": 2, "three": 3, "third": 3,
        "four": 4, "fourth": 4, "five": 5, "fifth": 5, "six": 6, "sixth": 6,
        "seven": 7, "seventh": 7, "eight": 8, "eighth": 8, "nine": 9, "ninth": 9,
        "ten": 10, "tenth": 10, "eleven": 11, "eleventh": 11,
        "twelve": 12, "twelfth": 12, "thirteen": 13, "thirteenth": 13,
        "fourteen": 14, "fourteenth": 14, "fifteen": 15, "fifteenth": 15,
        "sixteen": 16, "sixteenth": 16, "seventeen": 17, "seventeenth": 17,
        "eighteen": 18, "eighteenth": 18, "nineteen": 19, "nineteenth": 19,
    ]

    private static let tens: [String: Int] = [
        "twenty": 20, "twentieth": 20, "thirty": 30, "thirtieth": 30,
        "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90,
    ]

    public static func format(_ text: String) -> String {
        let tokens = tokenize(text)
        let clean = tokens.map { cleaned($0.raw) }
        var result = ""
        var cursor = text.startIndex
        var index = 0

        while index < tokens.count {
            guard let month = months[clean[index]],
                  let day = number(clean, at: index + 1, maximum: 31), day.value > 0 else {
                index += 1
                continue
            }
            let afterDay = index + 1 + day.length
            let year = year(clean, at: afterDay)
            let length = 1 + day.length + (year?.length ?? 0)
            let first = tokens[index]
            let last = tokens[index + length - 1]
            result += text[cursor..<first.start]
            result += leadingPunctuation(first.raw)
            result += "\(month) \(day.value)"
            if let year { result += ", \(year.value)" }
            result += trailingPunctuation(last.raw)
            cursor = last.end
            index += length
        }
        result += text[cursor...]
        return result
    }

    private static func year(_ tokens: [String], at index: Int) -> NumberMatch? {
        guard index < tokens.count else { return nil }
        if let value = Int(tokens[index]), (1000...2999).contains(value) {
            return NumberMatch(value: value, length: 1)
        }
        guard tokens[index] == "twenty",
              let tail = number(tokens, at: index + 1, maximum: 99) else { return nil }
        return NumberMatch(value: 2000 + tail.value, length: 1 + tail.length)
    }

    private static func number(_ tokens: [String], at index: Int, maximum: Int) -> NumberMatch? {
        guard index < tokens.count else { return nil }
        let token = tokens[index]
        let digits = token.trimmingCharacters(in: CharacterSet.letters)
        if let value = Int(digits), (0...maximum).contains(value) {
            return NumberMatch(value: value, length: 1)
        }
        let hyphenParts = token.split(separator: "-").map(String.init)
        if hyphenParts.count == 2, let ten = tens[hyphenParts[0]], let one = small[hyphenParts[1]],
           ten + one <= maximum {
            return NumberMatch(value: ten + one, length: 1)
        }
        if let value = small[token], value <= maximum {
            return NumberMatch(value: value, length: 1)
        }
        if let ten = tens[token] {
            if index + 1 < tokens.count, let one = small[tokens[index + 1]], one < 10,
               ten + one <= maximum {
                return NumberMatch(value: ten + one, length: 2)
            }
            if ten <= maximum { return NumberMatch(value: ten, length: 1) }
        }
        return nil
    }

    private static func tokenize(_ text: String) -> [Token] {
        var result: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            guard index < text.endIndex else { break }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
            result.append(Token(raw: String(text[start..<index]), start: start, end: index))
        }
        return result
    }

    private static func cleaned(_ value: String) -> String {
        var token = Substring(value.lowercased())
        while let first = token.first, !(first.isLetter || first.isNumber) { token = token.dropFirst() }
        while let last = token.last, !(last.isLetter || last.isNumber) { token = token.dropLast() }
        return String(token)
    }

    private static func leadingPunctuation(_ value: String) -> String {
        String(value.prefix { !$0.isLetter && !$0.isNumber })
    }

    private static func trailingPunctuation(_ value: String) -> String {
        String(value.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
    }
}
