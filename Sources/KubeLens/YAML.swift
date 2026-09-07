import Foundation

/// Минимальный YAML: блочные мапы и списки, скаляры (plain / кавычки / `|` / `>`),
/// flow-коллекции `[]` `{}`, комментарии. Ровно то подмножество, которым пишут
/// kubeconfig kubectl, clouds и человек в редакторе. Якоря и теги не поддерживаются —
/// в kubeconfig они не встречаются, а молча терять данные нельзя, поэтому ошибка.
///
/// Порядок ключей сохраняется, неизвестные поля проходят сквозь редактор нетронутыми.
struct YAMLPair: Equatable {
    var key: String
    var value: YAMLNode
}

indirect enum YAMLNode: Equatable {
    /// `quoted` — скаляр был в кавычках (или обязан быть, чтобы не стать числом/булем).
    case scalar(String, quoted: Bool)
    case null
    case mapping([YAMLPair])
    case sequence([YAMLNode])

    /// Строка из редактора: кавычки ставим, если без них YAML прочитает не строку.
    static func string(_ s: String) -> YAMLNode { .scalar(s, quoted: YAML.looksNonString(s)) }
    static func bool(_ b: Bool) -> YAMLNode { .scalar(b ? "true" : "false", quoted: false) }
    static let emptyMapping = YAMLNode.mapping([])

    var string: String? {
        if case .scalar(let s, _) = self { return s }
        return nil
    }
    var bool: Bool? {
        guard let s = string?.lowercased() else { return nil }
        if ["true", "yes", "on", "y"].contains(s) { return true }
        if ["false", "no", "off", "n"].contains(s) { return false }
        return nil
    }
    var pairs: [YAMLPair]? {
        if case .mapping(let p) = self { return p }
        return nil
    }
    var items: [YAMLNode]? {
        if case .sequence(let i) = self { return i }
        return nil
    }
    var isNull: Bool { self == .null }

    /// Доступ по ключу для мапы. Присваивание `nil` удаляет ключ, порядок остальных не меняется.
    subscript(key: String) -> YAMLNode? {
        get { pairs?.first { $0.key == key }?.value }
        set {
            var p = pairs ?? []
            if let i = p.firstIndex(where: { $0.key == key }) {
                if let v = newValue { p[i].value = v } else { p.remove(at: i) }
            } else if let v = newValue {
                p.append(YAMLPair(key: key, value: v))
            }
            self = .mapping(p)
        }
    }

    /// Строковое поле мапы; пустая строка при записи удаляет ключ.
    func str(_ key: String) -> String? { self[key]?.string }
    mutating func setStr(_ key: String, _ value: String?) {
        if let v = value, !v.isEmpty { self[key] = .string(v) } else { self[key] = nil }
    }
    mutating func setBool(_ key: String, _ value: Bool, defaultValue: Bool = false) {
        self[key] = value == defaultValue ? nil : .bool(value)
    }
}

enum YAMLError: LocalizedError {
    case syntax(line: Int, String)
    case unsupported(line: Int, String)

    var errorDescription: String? {
        switch self {
        case .syntax(let l, let m): return "YAML, строка \(l): \(m)"
        case .unsupported(let l, let m): return "YAML, строка \(l): \(m)"
        }
    }
}

enum YAML {
    static func parse(_ text: String) throws -> YAMLNode { var p = YAMLParser(text); return try p.parseDocument() }
    static func emit(_ node: YAMLNode) -> String { YAMLEmitter.emit(node) }

    /// Что YAML 1.1 (go-yaml, а значит и kubectl) прочитает не как строку.
    static func looksNonString(_ s: String) -> Bool {
        if s.isEmpty { return true }
        let l = s.lowercased()
        if ["true", "false", "yes", "no", "on", "off", "y", "n", "null", "~", ".inf", "-.inf", "+.inf", ".nan"].contains(l) { return true }
        if numberRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil { return true }
        if dateRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil { return true }
        return false
    }

    private static let numberRegex = try! NSRegularExpression(
        pattern: #"^[-+]?(0x[0-9a-fA-F_]+|0o?[0-7_]+|0b[01_]+|(\d[\d_]*)?(\.\d*)?([eE][-+]?\d+)?|\d[\d_]*(:[0-5]?\d)+(\.\d*)?)$"#)
    private static let dateRegex = try! NSRegularExpression(pattern: #"^\d{4}-\d{1,2}-\d{1,2}"#)
}

// MARK: - Parser

private struct YAMLParser {
    struct Line {
        var indent: Int
        var text: String     // без комментария и хвостовых пробелов
        let rawIndex: Int
    }

    private let raw: [String]
    private var lines: [Line] = []
    private var pos = 0

    init(_ text: String) {
        raw = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [Line] = []
        var stop = false
        for (i, r) in raw.enumerated() where !stop {
            let indent = r.prefix { $0 == " " }.count
            let content = Self.stripComment(String(r.dropFirst(indent)))
            if content.isEmpty { continue }
            if indent == 0 {
                if content == "---" || content.hasPrefix("--- ") { continue }
                if content == "..." { stop = true; continue }
                if content.hasPrefix("%") { continue }
            }
            out.append(Line(indent: indent, text: content, rawIndex: i))
        }
        lines = out
    }

    /// Обрезает ` # комментарий`, не трогая `#` внутри кавычек и без пробела перед ним (`a#b`).
    static func stripComment(_ s: String) -> String {
        var inSingle = false, inDouble = false, prevSpace = true, escaped = false
        var end = s.endIndex
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if inDouble {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inDouble = false }
            } else if inSingle {
                if c == "'" { inSingle = false }
            } else if c == "\"" { inDouble = true }
            else if c == "'" { inSingle = true }
            else if c == "#" && prevSpace { end = i; break }
            prevSpace = c == " " || c == "\t"
            i = s.index(after: i)
        }
        var result = String(s[..<end])
        while let last = result.last, last == " " || last == "\t" { result.removeLast() }
        return result
    }

    private var current: Line? { pos < lines.count ? lines[pos] : nil }
    private func lineNo(_ l: Line?) -> Int { (l?.rawIndex ?? raw.count - 1) + 1 }

    mutating func parseDocument() throws -> YAMLNode {
        guard let first = current else { return .null }
        let node = try parseBlock(minIndent: first.indent)
        if let extra = current {
            throw YAMLError.syntax(line: lineNo(extra), "неожиданный текст: \(extra.text)")
        }
        return node
    }

    private static func isSeqItem(_ t: String) -> Bool { t == "-" || t.hasPrefix("- ") }

    private mutating func parseBlock(minIndent: Int) throws -> YAMLNode {
        guard let line = current, line.indent >= minIndent else { return .null }
        if Self.isSeqItem(line.text) { return try parseSequence(indent: line.indent) }
        if Self.splitKey(line.text) != nil { return try parseMapping(indent: line.indent) }
        pos += 1
        return try parseValue(line.text, line: line, parentIndent: line.indent - 1)
    }

    private mutating func parseMapping(indent: Int) throws -> YAMLNode {
        var pairs: [YAMLPair] = []
        while let line = current, line.indent == indent, let (key, rest) = Self.splitKey(line.text) {
            pos += 1
            let value: YAMLNode
            if rest.isEmpty {
                if let next = current, next.indent > indent {
                    value = try parseBlock(minIndent: next.indent)
                } else if let next = current, next.indent == indent, Self.isSeqItem(next.text) {
                    value = try parseSequence(indent: indent)
                } else {
                    value = .null
                }
            } else {
                value = try parseValue(rest, line: line, parentIndent: indent)
            }
            if let i = pairs.firstIndex(where: { $0.key == key }) { pairs[i].value = value } else {
                pairs.append(YAMLPair(key: key, value: value))
            }
        }
        if let line = current, line.indent >= indent {
            throw YAMLError.syntax(line: lineNo(line), "ожидался ключ, получено: \(line.text)")
        }
        return .mapping(pairs)
    }

    private mutating func parseSequence(indent: Int) throws -> YAMLNode {
        var items: [YAMLNode] = []
        while let line = current, line.indent == indent, Self.isSeqItem(line.text) {
            let afterDash = line.text == "-" ? "" : String(line.text.dropFirst(1))
            let spaces = afterDash.prefix { $0 == " " }.count
            let rest = String(afterDash.dropFirst(spaces))
            if rest.isEmpty {
                pos += 1
                if let next = current, next.indent > indent {
                    items.append(try parseBlock(minIndent: next.indent))
                } else {
                    items.append(.null)
                }
            } else if Self.splitKey(rest) != nil || Self.isSeqItem(rest) {
                // `- key: v` — вложенная мапа начинается на этой же строке: подменяем строку.
                lines[pos] = Line(indent: indent + 1 + spaces, text: rest, rawIndex: line.rawIndex)
                items.append(try parseBlock(minIndent: indent + 1 + spaces))
            } else {
                pos += 1
                items.append(try parseValue(rest, line: line, parentIndent: indent))
            }
        }
        if let line = current, line.indent > indent {
            throw YAMLError.syntax(line: lineNo(line), "неожиданный отступ")
        }
        return .sequence(items)
    }

    /// `key: rest` → (key, rest). nil, если строка — не элемент мапы.
    static func splitKey(_ text: String) -> (String, String)? {
        if text.hasPrefix("? ") { return nil }
        let chars = Array(text)
        var i = 0
        var key = ""
        if chars[0] == "\"" || chars[0] == "'" {
            guard let (s, end) = try? parseQuoted(chars, from: 0) else { return nil }
            key = s
            i = end
            while i < chars.count, chars[i] == " " { i += 1 }
            guard i < chars.count, chars[i] == ":" else { return nil }
        } else {
            var depth = 0
            var found = -1
            while i < chars.count {
                let c = chars[i]
                if c == "[" || c == "{" { depth += 1 }
                if c == "]" || c == "}" { depth -= 1 }
                if c == ":" && depth <= 0 && (i + 1 == chars.count || chars[i + 1] == " ") { found = i; break }
                if (c == "#") && i > 0 && chars[i - 1] == " " { break }
                i += 1
            }
            guard found >= 0 else { return nil }
            key = String(chars[..<found]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty || key.hasPrefix("[") || key.hasPrefix("{") || key.hasPrefix("-") && key.count == 1 { return nil }
            i = found
        }
        // i указывает на ':'
        var rest = String(chars[(i + 1)...])
        rest = rest.trimmingCharacters(in: .whitespaces)
        return (key, rest)
    }

    private mutating func parseValue(_ text: String, line: Line, parentIndent: Int) throws -> YAMLNode {
        var t = text
        if t.hasPrefix("!") {
            // Тег вида `!!str 123` — сам тег игнорируем, значение читаем как строку в кавычках.
            let parts = t.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            t = parts.count > 1 ? String(parts[1]) : ""
            if parts[0] == "!!str" { return .scalar(t.isEmpty ? "" : (try Self.parseScalar(t, line: lineNo(line)).string ?? t), quoted: true) }
            if t.isEmpty { return .null }
        }
        if t.hasPrefix("&") || t.hasPrefix("*") {
            throw YAMLError.unsupported(line: lineNo(line), "якоря и ссылки (&/*) не поддерживаются")
        }
        if t.hasPrefix("|") || t.hasPrefix(">") {
            return try parseBlockScalar(header: t, line: line, parentIndent: parentIndent)
        }
        if t.hasPrefix("[") || t.hasPrefix("{") {
            var flow = t
            while !Self.flowBalanced(flow), let next = current {
                flow += " " + next.text
                pos += 1
            }
            var p = FlowParser(Array(flow), line: lineNo(line))
            return try p.parse()
        }
        return try Self.parseScalar(t, line: lineNo(line))
    }

    private static func flowBalanced(_ s: String) -> Bool {
        var depth = 0, inS = false, inD = false, esc = false
        for c in s {
            if inD { if esc { esc = false } else if c == "\\" { esc = true } else if c == "\"" { inD = false }; continue }
            if inS { if c == "'" { inS = false }; continue }
            switch c {
            case "\"": inD = true
            case "'": inS = true
            case "[", "{": depth += 1
            case "]", "}": depth -= 1
            default: break
            }
        }
        return depth <= 0
    }

    private mutating func parseBlockScalar(header: String, line: Line, parentIndent: Int) throws -> YAMLNode {
        let literal = header.hasPrefix("|")
        var chomp: Character = " "   // clip
        var explicit: Int? = nil
        for c in header.dropFirst() {
            if c == "-" || c == "+" { chomp = c } else if let d = c.wholeNumberValue, d > 0 { explicit = d } else if c == " " { break } else {
                throw YAMLError.syntax(line: lineNo(line), "непонятный заголовок блока: \(header)")
            }
        }
        var i = line.rawIndex + 1
        var blockIndent: Int? = explicit.map { parentIndent + 1 + $0 - 1 }
        var collected: [String] = []
        while i < raw.count {
            let r = raw[i]
            let ind = r.prefix { $0 == " " }.count
            let blank = r.trimmingCharacters(in: .whitespaces).isEmpty
            if blockIndent == nil {
                if blank { collected.append(""); i += 1; continue }
                if ind <= parentIndent { break }
                blockIndent = ind
            }
            if !blank && ind < blockIndent! { break }
            collected.append(blank ? "" : String(r.dropFirst(blockIndent!)))
            i += 1
        }
        // Переставляем позицию на первую содержательную строку после блока.
        while let l = current, l.rawIndex < i { pos += 1 }

        // Убираем хвостовые пустые строки, запоминая их для chomp `+`.
        var trailing = 0
        while let last = collected.last, last.isEmpty { collected.removeLast(); trailing += 1 }

        var body: String
        if literal {
            body = collected.joined(separator: "\n")
        } else {
            body = ""
            var prevBlank = false
            for (idx, l) in collected.enumerated() {
                if l.isEmpty { body += "\n"; prevBlank = true; continue }
                if idx > 0 && !prevBlank { body += l.hasPrefix(" ") ? "\n" : " " }
                body += l
                prevBlank = false
            }
        }
        switch chomp {
        case "-": break
        case "+": body += String(repeating: "\n", count: trailing + 1)
        default: if !collected.isEmpty { body += "\n" }
        }
        return .scalar(body, quoted: false)
    }

    static func parseScalar(_ t: String, line: Int) throws -> YAMLNode {
        if t.isEmpty { return .null }
        let chars = Array(t)
        if chars[0] == "\"" || chars[0] == "'" {
            let (s, end) = try parseQuoted(chars, from: 0)
            if end != chars.count {
                throw YAMLError.syntax(line: line, "лишний текст после кавычек: \(String(chars[end...]))")
            }
            return .scalar(s, quoted: true)
        }
        if t == "~" || t == "null" || t == "Null" || t == "NULL" { return .null }
        return .scalar(t, quoted: false)
    }

    /// Строка в кавычках начиная с chars[from]. Возвращает значение и индекс за закрывающей кавычкой.
    static func parseQuoted(_ chars: [Character], from: Int) throws -> (String, Int) {
        let q = chars[from]
        var i = from + 1
        var out = ""
        while i < chars.count {
            let c = chars[i]
            if q == "'" {
                if c == "'" {
                    if i + 1 < chars.count, chars[i + 1] == "'" { out.append("'"); i += 2; continue }
                    return (out, i + 1)
                }
                out.append(c); i += 1
            } else {
                if c == "\"" { return (out, i + 1) }
                if c == "\\" {
                    i += 1
                    guard i < chars.count else { break }
                    let e = chars[i]
                    switch e {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "0": out.append("\0")
                    case "\\": out.append("\\")
                    case "\"": out.append("\"")
                    case "/": out.append("/")
                    case " ": out.append(" ")
                    case "u", "x", "U":
                        let n = e == "x" ? 2 : (e == "u" ? 4 : 8)
                        let hex = String(chars[(i + 1)..<min(i + 1 + n, chars.count)])
                        if let v = UInt32(hex, radix: 16), let sc = Unicode.Scalar(v) { out.append(Character(sc)) }
                        i += n
                    default: out.append("\\"); out.append(e)
                    }
                    i += 1
                    continue
                }
                out.append(c); i += 1
            }
        }
        throw YAMLError.syntax(line: 0, "незакрытая кавычка")
    }
}

/// `[a, b]`, `{k: v}` — flow-коллекции, встречаются в `args: []` и `preferences: {}`.
private struct FlowParser {
    let c: [Character]
    var i = 0
    let line: Int

    init(_ chars: [Character], line: Int) { c = chars; self.line = line }

    mutating func parse() throws -> YAMLNode {
        let n = try node(terminators: [])
        skipWS()
        if i < c.count { throw YAMLError.syntax(line: line, "лишний текст в flow-коллекции") }
        return n
    }

    private mutating func skipWS() { while i < c.count, c[i] == " " || c[i] == "\t" || c[i] == "\n" { i += 1 } }

    private mutating func node(terminators: Set<Character>) throws -> YAMLNode {
        skipWS()
        guard i < c.count else { return .null }
        switch c[i] {
        case "[":
            i += 1
            var items: [YAMLNode] = []
            while true {
                skipWS()
                guard i < c.count else { throw YAMLError.syntax(line: line, "незакрытая [") }
                if c[i] == "]" { i += 1; return .sequence(items) }
                items.append(try node(terminators: [",", "]"]))
                skipWS()
                if i < c.count, c[i] == "," { i += 1 }
            }
        case "{":
            i += 1
            var pairs: [YAMLPair] = []
            while true {
                skipWS()
                guard i < c.count else { throw YAMLError.syntax(line: line, "незакрытая {") }
                if c[i] == "}" { i += 1; return .mapping(pairs) }
                let key = try scalarText(terminators: [":", ",", "}"]).string ?? ""
                skipWS()
                var value: YAMLNode = .null
                if i < c.count, c[i] == ":" { i += 1; value = try node(terminators: [",", "}"]) }
                pairs.append(YAMLPair(key: key, value: value))
                skipWS()
                if i < c.count, c[i] == "," { i += 1 }
            }
        default:
            return try scalarText(terminators: terminators)
        }
    }

    private mutating func scalarText(terminators: Set<Character>) throws -> YAMLNode {
        skipWS()
        guard i < c.count else { return .null }
        if c[i] == "\"" || c[i] == "'" {
            let (s, end) = try YAMLParser.parseQuoted(c, from: i)
            i = end
            return .scalar(s, quoted: true)
        }
        var s = ""
        while i < c.count {
            let ch = c[i]
            if terminators.contains(ch) {
                // `:` — разделитель только перед пробелом/концом/терминатором.
                if ch == ":" && i + 1 < c.count && !(c[i + 1] == " " || terminators.contains(c[i + 1])) { s.append(ch); i += 1; continue }
                break
            }
            s.append(ch); i += 1
        }
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t == "~" || t == "null" { return .null }
        return .scalar(t, quoted: false)
    }
}

// MARK: - Emitter

private enum YAMLEmitter {
    static func emit(_ node: YAMLNode) -> String {
        switch node {
        case .mapping(let p) where p.isEmpty: return "{}\n"
        case .sequence(let s) where s.isEmpty: return "[]\n"
        case .null: return "null\n"
        case .scalar(let s, let q): return (s.contains("\n") ? blockHeader(s) + "\n" + blockBody(s, indent: 2).joined(separator: "\n") : format(s, quoted: q)) + "\n"
        default: return lines(node, indent: 0).joined(separator: "\n") + "\n"
        }
    }

    private static func pad(_ n: Int) -> String { String(repeating: " ", count: n) }

    static func lines(_ node: YAMLNode, indent: Int) -> [String] {
        var out: [String] = []
        switch node {
        case .mapping(let pairs):
            for p in pairs {
                let k = pad(indent) + format(p.key, quoted: false) + ":"
                switch p.value {
                case .mapping(let m) where m.isEmpty: out.append(k + " {}")
                case .mapping: out.append(k); out += lines(p.value, indent: indent + 2)
                case .sequence(let s) where s.isEmpty: out.append(k + " []")
                case .sequence: out.append(k); out += lines(p.value, indent: indent)
                case .null: out.append(k + " null")
                case .scalar(let s, let q):
                    if s.contains("\n") {
                        out.append(k + " " + blockHeader(s))
                        out += blockBody(s, indent: indent + 2)
                    } else {
                        out.append(k + " " + format(s, quoted: q))
                    }
                }
            }
        case .sequence(let items):
            for item in items {
                switch item {
                case .mapping(let m) where m.isEmpty: out.append(pad(indent) + "- {}")
                case .sequence(let s) where s.isEmpty: out.append(pad(indent) + "- []")
                case .mapping, .sequence:
                    var sub = lines(item, indent: indent + 2)
                    if !sub.isEmpty { sub[0] = pad(indent) + "- " + sub[0].dropFirst(indent + 2) }
                    out += sub
                case .null: out.append(pad(indent) + "- null")
                case .scalar(let s, let q):
                    if s.contains("\n") {
                        out.append(pad(indent) + "- " + blockHeader(s))
                        out += blockBody(s, indent: indent + 2)
                    } else {
                        out.append(pad(indent) + "- " + format(s, quoted: q))
                    }
                }
            }
        case .null: out.append(pad(indent) + "null")
        case .scalar(let s, let q): out.append(pad(indent) + format(s, quoted: q))
        }
        return out
    }

    private static func blockHeader(_ s: String) -> String {
        let trailing = s.reversed().prefix { $0 == "\n" }.count
        let first = s.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        let indicator = first.hasPrefix(" ") ? "2" : ""
        switch trailing {
        case 0: return "|" + indicator + "-"
        case 1: return "|" + indicator
        default: return "|" + indicator + "+"
        }
    }

    private static func blockBody(_ s: String, indent: Int) -> [String] {
        var parts = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Один хвостовой перевод строки выражен заголовком `|`, остальные `|+` сохраняют сами.
        if parts.last == "" { parts.removeLast() }
        return parts.map { $0.isEmpty ? "" : pad(indent) + $0 }
    }

    static func format(_ s: String, quoted: Bool) -> String {
        if quoted || needsQuotes(s) { return quote(s) }
        return s
    }

    private static let specialStart: Set<Character> = ["?", ":", ",", "[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`"]

    static func needsQuotes(_ s: String) -> Bool {
        guard let f = s.first, let l = s.last else { return true }
        if f == " " || l == " " || f == "\t" || l == "\t" { return true }
        if specialStart.contains(f) { return true }
        if s == "-" || s.hasPrefix("- ") || s.hasPrefix("---") { return true }
        if s.contains(": ") || s.contains(" #") || l == ":" { return true }
        if s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return true }
        // Числа/були/null без кавычек — это не строка и была прочитана как есть: флаг `quoted`
        // решает, нужны ли кавычки, сам вид значения здесь ни при чём.
        return false
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if u.value < 0x20 || u.value == 0x7F { out += String(format: "\\u%04X", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}
