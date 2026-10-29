import Foundation

// The collectors used to be jq and Python scripts, and part of what they wrote
// is a data contract rather than presentation: event ids hash jq's text form of
// a number, the statusLine signature hashes jq's compact output, and ledger
// lines are what every report reads back. So this JSON model keeps object keys
// in insertion order, keeps number literals verbatim, and prints strings the
// way jq (or Python's json module, where Python wrote the file) prints them.

/// An order-preserving JSON value.
enum JSONValue {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    static func int(_ value: Int) -> JSONValue { .number(JSONNumber(value)) }
}

/// A JSON number that remembers how it was written.
struct JSONNumber {
    /// The text to print. Input literals are kept as they were read, which is
    /// what jq 1.7+ does for numbers it did not compute itself.
    let text: String

    init(literal: String) { text = literal }
    init(_ value: Int) { text = String(value) }

    /// A number jq computed (a sum, a difference): whole values print without
    /// a fraction.
    init(computed value: Double) {
        if value.isNaN {
            text = "null"
        } else if value == value.rounded(), abs(value) < 9.0e15 {
            text = String(Int64(value))
        } else {
            text = "\(value)"
        }
    }

    /// A Python float, printed the way `json.dump` prints it (`repr`).
    init(pythonFloat value: Double) {
        text = "\(value)"
    }

    var doubleValue: Double { Double(text) ?? .nan }

    private var isIntegerLiteral: Bool {
        !text.contains(".") && !text.contains("e") && !text.contains("E")
    }

    /// The literal as an integer, when it is written as one.
    var intValue: Int? {
        isIntegerLiteral ? Int(text) : nil
    }

    /// How jq 1.7+ prints the number: decNumber's to-scientific-string, which
    /// keeps "8.0" and "1.50" as written but turns "1e3" into "1E+3" and
    /// "0.0000001" into "1E-7".
    var jqText: String {
        let bytes = Array(text.utf8)
        var index = 0
        var negative = false
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") {
            negative = true
            index += 1
        }
        var digits: [UInt8] = []
        var exponent = 0
        var afterPoint = false
        while index < bytes.count, bytes[index] != UInt8(ascii: "e"), bytes[index] != UInt8(ascii: "E") {
            if bytes[index] == UInt8(ascii: ".") {
                afterPoint = true
            } else {
                digits.append(bytes[index])
                if afterPoint { exponent -= 1 }
            }
            index += 1
        }
        if index < bytes.count {
            index += 1
            var sign = 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
                if bytes[index] == UInt8(ascii: "-") { sign = -1 }
                index += 1
            }
            var value = 0
            while index < bytes.count, value < 1_000_000_000 {
                guard bytes[index] >= 0x30, bytes[index] <= 0x39 else { return text }
                value = value * 10 + Int(bytes[index] - 0x30)
                index += 1
            }
            exponent += sign * value
        }
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return text }
        while digits.count > 1, digits[0] == UInt8(ascii: "0") { digits.removeFirst() }

        let coefficient = String(decoding: digits, as: UTF8.self)
        let adjusted = exponent + digits.count - 1
        var result = negative ? "-" : ""
        if exponent <= 0 && adjusted >= -6 {
            if exponent == 0 {
                result += coefficient
            } else {
                let integerDigits = digits.count + exponent
                if integerDigits > 0 {
                    result += String(coefficient.prefix(integerDigits)) + "." + String(coefficient.dropFirst(integerDigits))
                } else {
                    result += "0." + String(repeating: "0", count: -integerDigits) + coefficient
                }
            }
        } else {
            result += String(coefficient.prefix(1))
            if digits.count > 1 { result += "." + String(coefficient.dropFirst()) }
            result += "E" + (adjusted >= 0 ? "+" : "-") + String(abs(adjusted))
        }
        return result
    }

    /// How Python's json module prints the parsed number: ints as digits,
    /// everything else as a float (`repr`).
    var pythonText: String {
        if isIntegerLiteral { return text == "-0" ? "0" : text }
        guard let value = Double(text), value.isFinite else { return text }
        return "\(value)"
    }
}

/// A JSON object whose keys keep their first-insertion order (as in jq and in
/// Python dicts). Re-setting an existing key keeps its position.
struct JSONObject {
    private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    init() {}

    init(_ pairs: KeyValuePairs<String, JSONValue>) {
        for (key, value) in pairs { self[key] = value }
    }

    subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil {
                    keys.append(key)
                }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    var isEmpty: Bool { keys.isEmpty }
    var count: Int { keys.count }

    var entries: [(key: String, value: JSONValue)] {
        keys.map { ($0, storage[$0] ?? .null) }
    }
}

// MARK: - jq semantics

extension JSONValue {
    /// jq truthiness: only `null` and `false` are false.
    var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let value): return value
        default: return true
        }
    }

    /// Python truthiness, for code ported from the Python collectors.
    var isPythonTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let value): return value
        case .number(let number): return number.doubleValue != 0
        case .string(let string): return !string.isEmpty
        case .array(let array): return !array.isEmpty
        case .object(let object): return !object.isEmpty
        }
    }

    var objectValue: JSONObject? {
        if case .object(let object) = self { return object }
        return nil
    }

    var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    /// jq's `.key`: a missing key or a null input gives null; indexing
    /// anything else is an error (nil here).
    func jqField(_ key: String) -> JSONValue? {
        switch self {
        case .null: return .null
        case .object(let object): return object[key] ?? .null
        default: return nil
        }
    }

    /// `.a.b.c`, or nil where jq would raise an error.
    func jqPath(_ keys: [String]) -> JSONValue? {
        var current = self
        for key in keys {
            guard let next = current.jqField(key) else { return nil }
            current = next
        }
        return current
    }

    /// `path // empty` as `$(jq -r ...)` sees it: nil for null/false and
    /// for an error alike (both print nothing).
    func jqValue(_ keys: [String]) -> JSONValue? {
        guard let value = jqPath(keys), value.isTruthy else { return nil }
        return value
    }

    /// `path // fallback`. jq does not hide errors behind `//` (an error on
    /// the left fails the whole expression), so nil means "jq raised an error".
    func jqValue(_ keys: [String], or fallback: JSONValue) -> JSONValue? {
        guard let value = jqPath(keys) else { return nil }
        return value.isTruthy ? value : fallback
    }

    /// What `jq -r` prints for this value: strings raw, anything else as
    /// regular (pretty) JSON.
    var jqRawText: String {
        if case .string(let string) = self { return string }
        return prettyText
    }

    /// jq's `tostring`.
    var jqToString: String {
        if case .string(let string) = self { return string }
        return compactText
    }

    private var jqKindRank: Int {
        switch self {
        case .null: return 0
        case .bool(let value): return value ? 2 : 1
        case .number: return 3
        case .string: return 4
        case .array: return 5
        case .object: return 6
        }
    }

    /// jq's total order (`sort`, `group_by`, `max`, `<`): null < false < true
    /// < numbers < strings (byte order) < arrays < objects.
    static func jqCompare(_ left: JSONValue, _ right: JSONValue) -> Int {
        let leftRank = left.jqKindRank
        let rightRank = right.jqKindRank
        if leftRank != rightRank { return leftRank < rightRank ? -1 : 1 }

        switch (left, right) {
        case (.number(let a), .number(let b)):
            let x = a.doubleValue
            let y = b.doubleValue
            return x < y ? -1 : (x > y ? 1 : 0)
        case (.string(let a), .string(let b)):
            return compareBytes(a, b)
        case (.array(let a), .array(let b)):
            for (x, y) in zip(a, b) {
                let result = jqCompare(x, y)
                if result != 0 { return result }
            }
            return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
        case (.object(let a), .object(let b)):
            let aKeys = a.keys.sorted { compareBytes($0, $1) < 0 }
            let bKeys = b.keys.sorted { compareBytes($0, $1) < 0 }
            let keyOrder = jqCompare(.array(aKeys.map { .string($0) }), .array(bKeys.map { .string($0) }))
            if keyOrder != 0 { return keyOrder }
            for key in aKeys {
                let result = jqCompare(a[key] ?? .null, b[key] ?? .null)
                if result != 0 { return result }
            }
            return 0
        default:
            return 0
        }
    }

    /// Byte-wise (C locale / memcmp) string order.
    static func compareBytes(_ a: String, _ b: String) -> Int {
        var left = a.utf8.makeIterator()
        var right = b.utf8.makeIterator()
        while true {
            switch (left.next(), right.next()) {
            case (nil, nil): return 0
            case (nil, _): return -1
            case (_, nil): return 1
            case (let x?, let y?):
                if x != y { return x < y ? -1 : 1 }
            }
        }
    }
}

/// jq's `sort_by(f)`: stable, by jq order of the key.
func jqStableSort(_ values: [JSONValue], by key: (JSONValue) -> JSONValue) -> [JSONValue] {
    let keyed = values.enumerated().map { (index: $0.offset, key: key($0.element), value: $0.element) }
    return keyed.sorted { left, right in
        let order = JSONValue.jqCompare(left.key, right.key)
        return order != 0 ? order < 0 : left.index < right.index
    }.map { $0.value }
}

/// jq's `group_by(f)`: sort by the key, then split into runs of equal keys.
func jqGroupBy(_ values: [JSONValue], by key: (JSONValue) -> JSONValue) -> [[JSONValue]] {
    var groups: [[JSONValue]] = []
    var lastKey: JSONValue?
    for value in jqStableSort(values, by: key) {
        let valueKey = key(value)
        if let previous = lastKey, JSONValue.jqCompare(previous, valueKey) == 0 {
            groups[groups.count - 1].append(value)
        } else {
            groups.append([value])
        }
        lastKey = valueKey
    }
    return groups
}

/// jq's `max_by(f)`: when several elements tie, the last one wins.
func jqMaxBy(_ values: [JSONValue], by key: (JSONValue) -> JSONValue) -> JSONValue? {
    var best: JSONValue?
    var bestKey: JSONValue?
    for value in values {
        let valueKey = key(value)
        if let currentKey = bestKey, JSONValue.jqCompare(valueKey, currentKey) < 0 {
            continue
        }
        best = value
        bestKey = valueKey
    }
    return best
}

// MARK: - Printing

extension JSONValue {
    /// `jq -c` output.
    var compactText: String {
        var out = ""
        write(into: &out, style: .jqCompact, depth: 0)
        return out
    }

    /// jq's default output: two-space indent.
    var prettyText: String {
        var out = ""
        write(into: &out, style: .jqPretty, depth: 0)
        return out
    }

    /// Python's `json.dumps(value, ensure_ascii=..., separators=...)`.
    func pythonText(ensureASCII: Bool, compact: Bool) -> String {
        var out = ""
        write(into: &out, style: .python(ensureASCII: ensureASCII, compact: compact), depth: 0)
        return out
    }

    private enum Style {
        case jqCompact
        case jqPretty
        case python(ensureASCII: Bool, compact: Bool)

        var pretty: Bool {
            if case .jqPretty = self { return true }
            return false
        }

        var itemSeparator: String {
            if case .python(_, let compact) = self, !compact { return ", " }
            return ","
        }

        var keySeparator: String {
            switch self {
            case .jqCompact: return ":"
            case .jqPretty: return ": "
            case .python(_, let compact): return compact ? ":" : ": "
            }
        }
    }

    private func write(into out: inout String, style: Style, depth: Int) {
        switch self {
        case .null:
            out += "null"
        case .bool(let value):
            out += value ? "true" : "false"
        case .number(let number):
            if case .python = style {
                out += number.pythonText
            } else {
                out += number.jqText
            }
        case .string(let string):
            JSONValue.writeString(string, into: &out, style: style)
        case .array(let items):
            if items.isEmpty {
                out += "[]"
                return
            }
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += style.itemSeparator }
                if style.pretty { JSONValue.newline(&out, depth: depth + 1) }
                item.write(into: &out, style: style, depth: depth + 1)
            }
            if style.pretty { JSONValue.newline(&out, depth: depth) }
            out += "]"
        case .object(let object):
            if object.isEmpty {
                out += "{}"
                return
            }
            out += "{"
            for (index, entry) in object.entries.enumerated() {
                if index > 0 { out += style.itemSeparator }
                if style.pretty { JSONValue.newline(&out, depth: depth + 1) }
                JSONValue.writeString(entry.key, into: &out, style: style)
                out += style.keySeparator
                entry.value.write(into: &out, style: style, depth: depth + 1)
            }
            if style.pretty { JSONValue.newline(&out, depth: depth) }
            out += "}"
        }
    }

    private static func newline(_ out: inout String, depth: Int) {
        out += "\n"
        out += String(repeating: "  ", count: depth)
    }

    private static func writeString(_ string: String, into out: inout String, style: Style) {
        out += "\""
        for scalar in string.unicodeScalars {
            let value = scalar.value
            switch value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0C: out += "\\f"
            case 0x0D: out += "\\r"
            case 0x00..<0x20:
                out += hexEscape(value)
            case 0x7F:
                // jq escapes DEL; Python only does under ensure_ascii.
                if case .python(let ascii, _) = style, !ascii {
                    out.unicodeScalars.append(scalar)
                } else {
                    out += hexEscape(value)
                }
            default:
                if value > 0x7F, case .python(let ascii, _) = style, ascii {
                    if value > 0xFFFF {
                        let offset = value - 0x10000
                        out += hexEscape(0xD800 | (offset >> 10))
                        out += hexEscape(0xDC00 | (offset & 0x3FF))
                    } else {
                        out += hexEscape(value)
                    }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    private static func hexEscape(_ value: UInt32) -> String {
        let hex = String(value, radix: 16)
        return "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }
}

// MARK: - Parsing

struct JSONParseError: Error {
    let offset: Int
}

/// A strict RFC 8259 parser over UTF-8 bytes that keeps key order and number
/// literals. Invalid UTF-8 inside strings becomes U+FFFD, as in jq.
///
/// It reads the bytes where they are: the ledger summary parses up to 50 MB
/// every minute, and a copy into an array would double that.
struct JSONParser {
    private let bytes: UnsafeBufferPointer<UInt8>
    private var index = 0
    private var depth = 0
    /// Background threads have small stacks; real inputs nest a handful deep.
    private static let maximumDepth = 200

    private init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    /// Exactly one value, optionally surrounded by whitespace.
    static func parse(_ data: Data) throws -> JSONValue {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> JSONValue in
            var parser = JSONParser(bytes: raw.bindMemory(to: UInt8.self))
            parser.skipWhitespace()
            let value = try parser.parseValue()
            parser.skipWhitespace()
            guard parser.index == parser.bytes.count else { throw JSONParseError(offset: parser.index) }
            return value
        }
    }

    static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    /// A whitespace-separated stream of values, the way jq reads its input.
    /// Values parsed before a syntax error are returned along with `failed`.
    static func parseStream(_ data: Data) -> (values: [JSONValue], failed: Bool) {
        var values: [JSONValue] = []
        let complete = forEachValue(in: data) { values.append($0) }
        return (values, !complete)
    }

    /// Hands each top-level value of a stream to `body` as soon as it is
    /// parsed. Returns false on a syntax error (values before it were
    /// already delivered).
    static func forEachValue(in data: Data, _ body: (JSONValue) -> Void) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            var parser = JSONParser(bytes: raw.bindMemory(to: UInt8.self))
            while true {
                parser.skipWhitespace()
                if parser.index >= parser.bytes.count { return true }
                guard let value = try? parser.parseValue() else { return false }
                body(value)
            }
        }
    }

    static func parseStream(_ text: String) -> (values: [JSONValue], failed: Bool) {
        parseStream(Data(text.utf8))
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func parseValue() throws -> JSONValue {
        guard index < bytes.count else { throw JSONParseError(offset: index) }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw JSONParseError(offset: index)
        }
    }

    private mutating func expectLiteral(_ literal: String) throws {
        for byte in literal.utf8 {
            guard index < bytes.count, bytes[index] == byte else { throw JSONParseError(offset: index) }
            index += 1
        }
    }

    private mutating func enter() throws {
        depth += 1
        if depth > JSONParser.maximumDepth { throw JSONParseError(offset: index) }
    }

    private mutating func parseObject() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1  // {
        var object = JSONObject()
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw JSONParseError(offset: index) }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw JSONParseError(offset: index) }
            index += 1
            skipWhitespace()
            object[key] = try parseValue()
            skipWhitespace()
            guard index < bytes.count else { throw JSONParseError(offset: index) }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(object)
            }
            throw JSONParseError(offset: index)
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1  // [
        var items: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            items.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw JSONParseError(offset: index) }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            throw JSONParseError(offset: index)
        }
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = index
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count, isDigit(bytes[index]) else { throw JSONParseError(offset: index) }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else {
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard index < bytes.count, isDigit(bytes[index]) else { throw JSONParseError(offset: index) }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard index < bytes.count, isDigit(bytes[index]) else { throw JSONParseError(offset: index) }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        let literal = String(decoding: bytes[start..<index], as: UTF8.self)
        return .number(JSONNumber(literal: literal))
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private mutating func parseString() throws -> String {
        index += 1  // opening quote
        let start = index
        // Fast path: no escapes.
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                let string = String(decoding: bytes[start..<index], as: UTF8.self)
                index += 1
                return string
            }
            if byte == UInt8(ascii: "\\") { break }
            if byte < 0x20 { throw JSONParseError(offset: index) }
            index += 1
        }

        var buffer = [UInt8](bytes[start..<index])
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                return String(decoding: buffer, as: UTF8.self)
            }
            if byte < 0x20 { throw JSONParseError(offset: index) }
            if byte != UInt8(ascii: "\\") {
                buffer.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < bytes.count else { throw JSONParseError(offset: index) }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "\""): buffer.append(0x22)
            case UInt8(ascii: "\\"): buffer.append(0x5C)
            case UInt8(ascii: "/"): buffer.append(0x2F)
            case UInt8(ascii: "b"): buffer.append(0x08)
            case UInt8(ascii: "f"): buffer.append(0x0C)
            case UInt8(ascii: "n"): buffer.append(0x0A)
            case UInt8(ascii: "r"): buffer.append(0x0D)
            case UInt8(ascii: "t"): buffer.append(0x09)
            case UInt8(ascii: "u"):
                var code = try parseHex4()
                if (0xD800...0xDBFF).contains(code),
                   index + 5 < bytes.count,
                   bytes[index] == UInt8(ascii: "\\"),
                   bytes[index + 1] == UInt8(ascii: "u") {
                    let save = index
                    index += 2
                    let low = try parseHex4()
                    if (0xDC00...0xDFFF).contains(low) {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        index = save
                    }
                }
                // A lone surrogate is not a scalar; jq reads it as U+FFFD.
                let replacement: String
                if let scalar = Unicode.Scalar(code) {
                    replacement = String(Character(scalar))
                } else {
                    replacement = "\u{FFFD}"
                }
                buffer.append(contentsOf: Array(replacement.utf8))
            default:
                throw JSONParseError(offset: index - 1)
            }
        }
        throw JSONParseError(offset: index)
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw JSONParseError(offset: index) }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: throw JSONParseError(offset: index)
            }
            value = value * 16 + digit
            index += 1
        }
        return value
    }
}
