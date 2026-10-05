import Foundation

// The command bar's calculator: a small recursive-descent parser over a token list (never
// NSExpression on what was typed). Arithmetic, parentheses, powers, %, "12% of 340" / "12% di 340",
// factorial, a few functions and constants, hex/bin/oct literals and "255 in hex".

public enum CalcError: Error, Equatable, Sendable {
    case syntax
    case divisionByZero
    case domain
    case overflow
}

public enum NumberBase: String, Sendable, Equatable { case hex, bin, oct, dec }

public struct CalcResult: Equatable, Sendable {
    public var value: Double
    /// The base asked for ("in hex"), or the base of a literal typed alone ("0xff" → decimal).
    public var base: NumberBase?
    public var usedBaseLiteral: Bool
}

public enum Calculator {
    /// nil when the input isn't a calculation (a word, a lone number); throws when it is one but
    /// cannot be computed. `decimalComma`: "1,5" is 1.5 and "1.000" is a thousand (Italian).
    public static func evaluate(_ input: String, decimalComma: Bool = false) throws -> CalcResult? {
        var text = input.lowercased().trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("=") { text.removeLast(); text = text.trimmingCharacters(in: .whitespaces) }
        guard !text.isEmpty, text.contains(where: \.isNumber) else { return nil }
        let (body, base) = splitBase(text)
        let tokens: [Token]
        do { tokens = try lex(body, decimalComma: decimalComma) } catch { return nil }
        guard isCalculation(tokens, base: base) else { return nil }
        var p = Parser(tokens: tokens)
        let v = try p.parseExpression()
        guard p.atEnd else { throw CalcError.syntax }
        let value = v.number
        if value.isNaN { throw CalcError.domain }
        if !value.isFinite { throw CalcError.overflow }
        let literal = tokens.contains { if case .number(_, true) = $0 { return true } else { return false } }
        return CalcResult(value: value, base: base ?? (literal ? .dec : nil), usedBaseLiteral: literal)
    }

    // MARK: Output base

    private static let baseWords: [(String, NumberBase)] = [
        ("hexadecimal", .hex), ("esadecimale", .hex), ("hex", .hex),
        ("binary", .bin), ("binario", .bin), ("bin", .bin),
        ("octal", .oct), ("ottale", .oct), ("oct", .oct),
        ("decimal", .dec), ("decimale", .dec), ("dec", .dec),
    ]

    static func splitBase(_ s: String) -> (String, NumberBase?) {
        for sep in [" in ", " to ", " as ", " a "] {
            guard let r = s.range(of: sep, options: .backwards) else { continue }
            let tail = s[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if let b = baseWords.first(where: { $0.0 == tail })?.1 {
                return (String(s[..<r.lowerBound]), b)
            }
        }
        return (s, nil)
    }

    // MARK: Tokens

    enum Token: Equatable {
        case number(Double, Bool)     // value, typed as a hex/bin/oct literal
        case op(Character)            // + - * / ^ ( ) % !
        case of                       // "12% of 340"
        case mod
        case function(String)
        case constant(Double)
    }

    static let functions: Set<String> = ["sqrt", "cbrt", "abs", "round", "floor", "ceil", "ln", "log", "log2", "log10",
                                         "exp", "sin", "cos", "tan", "asin", "acos", "atan"]
    static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E, "tau": 2 * .pi]

    static func lex(_ s: String, decimalComma: Bool) throws -> [Token] {
        var out: [Token] = []
        let chars = Array(s)
        var i = 0
        func prevIsValue() -> Bool {
            switch out.last {
            case .number?, .constant?, .op(")")?, .op("%")?, .op("!")?: return true
            default: return false
            }
        }
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" { i += 1; continue }
            // Base literals.
            if c == "0", i + 1 < chars.count, let radix = ["x": 16, "b": 2, "o": 8][String(chars[i + 1])] {
                var j = i + 2, digits = ""
                while j < chars.count, chars[j].isHexDigit, Int(String(chars[j]), radix: radix) != nil { digits.append(chars[j]); j += 1 }
                if !digits.isEmpty, j == chars.count || !chars[j].isLetter && !chars[j].isNumber {
                    guard let v = UInt64(digits, radix: radix) else { throw CalcError.overflow }
                    out.append(.number(Double(v), true))
                    i = j
                    continue
                }
            }
            if c.isNumber || ((c == "." || c == ",") && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i, raw = ""
                while j < chars.count, chars[j].isNumber || chars[j] == "." || chars[j] == "," {
                    // A separator must be followed by a digit (else it ends the number).
                    if !chars[j].isNumber, !(j + 1 < chars.count && chars[j + 1].isNumber) { break }
                    raw.append(chars[j]); j += 1
                }
                // Exponent: 1e3, 2.5e-4.
                if j + 1 < chars.count, chars[j] == "e" {
                    var k = j + 1
                    var exp = ""
                    if chars[k] == "-" || chars[k] == "+" { exp.append(chars[k]); k += 1 }
                    var digits = ""
                    while k < chars.count, chars[k].isNumber { digits.append(chars[k]); k += 1 }
                    if !digits.isEmpty, k == chars.count || !chars[k].isLetter {
                        raw += "e" + exp + digits
                        j = k
                    }
                }
                guard let v = parseNumber(raw, decimalComma: decimalComma) else { throw CalcError.syntax }
                out.append(.number(v, false))
                i = j
                continue
            }
            if "+-*/^()%!".contains(c) {
                // ** is a power.
                if c == "*", i + 1 < chars.count, chars[i + 1] == "*" { out.append(.op("^")); i += 2; continue }
                out.append(.op(c)); i += 1; continue
            }
            switch c {
            case "×", "·", "∙": out.append(.op("*")); i += 1; continue
            case "÷": out.append(.op("/")); i += 1; continue
            case "−", "–": out.append(.op("-")); i += 1; continue
            case "√": out.append(.function("sqrt")); i += 1; continue
            case "π": out.append(.constant(.pi)); i += 1; continue
            default: break
            }
            // "3x4", "3 x 4": times, after a value.
            if c == "x", prevIsValue() { out.append(.op("*")); i += 1; continue }
            if c.isLetter {
                var j = i, word = ""
                while j < chars.count, chars[j].isLetter || chars[j].isNumber && !word.isEmpty { word.append(chars[j]); j += 1 }
                i = j
                switch word {
                case "of", "di", "del", "dei", "della": out.append(.of)
                case "mod": out.append(.mod)
                case "percent", "percento": out.append(.op("%"))
                case "per":
                    // "per cento" = %; anything else is not ours.
                    var k = i
                    while k < chars.count, chars[k] == " " { k += 1 }
                    guard k + 5 <= chars.count, String(chars[k..<(k + 5)]) == "cento" else { throw CalcError.syntax }
                    out.append(.op("%"))
                    i = k + 5
                default:
                    if functions.contains(word) { out.append(.function(word)) }
                    else if let k = constants[word] { out.append(.constant(k)) }
                    else { throw CalcError.syntax }
                }
                continue
            }
            throw CalcError.syntax
        }
        return out
    }

    /// "1,234.5", "1.234,5" (both separators: the last one is the decimal), "3,5" (Italian or not:
    /// a comma before anything but exactly three digits is a decimal point).
    static func parseNumber(_ raw: String, decimalComma: Bool) -> Double? {
        var s = raw
        let mantissa = s.split(separator: "e", maxSplits: 1).first.map(String.init) ?? s
        let exponent = s.contains("e") ? "e" + (s.split(separator: "e", maxSplits: 1).last.map(String.init) ?? "") : ""
        s = mantissa
        let dots = s.filter { $0 == "." }.count, commas = s.filter { $0 == "," }.count
        if dots > 0, commas > 0 {
            let lastDot = s.lastIndex(of: ".")!, lastComma = s.lastIndex(of: ",")!
            if lastComma > lastDot { s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
            else { s = s.replacingOccurrences(of: ",", with: "") }
        } else if commas > 0 {
            let groups = s.split(separator: ",", omittingEmptySubsequences: false)
            let grouping = !decimalComma && (commas > 1 || groups.last?.count == 3) && groups.dropFirst().allSatisfy { $0.count == 3 }
            s = grouping ? s.replacingOccurrences(of: ",", with: "") : (commas == 1 ? s.replacingOccurrences(of: ",", with: ".") : "x")
        } else if dots > 0 {
            let groups = s.split(separator: ".", omittingEmptySubsequences: false)
            let grouping = (dots > 1 || decimalComma && groups.last?.count == 3) && groups.dropFirst().allSatisfy { $0.count == 3 }
            if grouping { s = s.replacingOccurrences(of: ".", with: "") } else if dots > 1 { return nil }
        }
        return Double(s + exponent)
    }

    /// Anything with a number that parses is ours, a bare number included ("25" shows 25 ready to
    /// copy, ahead of any module's reading of it). Words alone ("e", "pi") are not.
    static func isCalculation(_ tokens: [Token], base: NumberBase?) -> Bool {
        tokens.contains { if case .number = $0 { return true } else { return false } }
    }

    // MARK: Parser

    /// A value, or a percentage still waiting to know what it is a percentage of.
    struct Value {
        var raw: Double
        var percent = false
        var number: Double { percent ? raw / 100 : raw }
    }

    struct Parser {
        let tokens: [Token]
        var i = 0
        var depth = 0
        var atEnd: Bool { i == tokens.count }

        init(tokens: [Token]) { self.tokens = tokens }

        mutating func peek() -> Token? { i < tokens.count ? tokens[i] : nil }
        mutating func next() -> Token? { defer { i += 1 }; return peek() }

        mutating func parseExpression() throws -> Value {
            depth += 1
            defer { depth -= 1 }
            guard depth < 64 else { throw CalcError.syntax }
            var left = try parseTerm()
            while let t = peek(), t == .op("+") || t == .op("-") {
                i += 1
                let right = try parseTerm()
                let sign: Double = t == .op("+") ? 1 : -1
                // 200 + 10% = 220: a percentage added to something is a percentage of it.
                let r = right.percent ? left.number * right.raw / 100 : right.number
                left = Value(raw: left.number + sign * r)
            }
            return left
        }

        mutating func parseTerm() throws -> Value {
            var left = try parseUnary()
            while let t = peek() {
                switch t {
                case .op("*"), .of:
                    i += 1
                    left = Value(raw: left.number * (try parseUnary()).number)
                case .op("/"):
                    i += 1
                    let d = (try parseUnary()).number
                    guard d != 0 else { throw CalcError.divisionByZero }
                    left = Value(raw: left.number / d)
                case .mod:
                    i += 1
                    let d = (try parseUnary()).number
                    guard d != 0 else { throw CalcError.divisionByZero }
                    left = Value(raw: left.number.truncatingRemainder(dividingBy: d))
                case .op("("), .function, .constant:
                    // Implicit multiplication: 2(3+4), 2pi, (1+2)(3+4).
                    left = Value(raw: left.number * (try parseUnary()).number)
                default:
                    return left
                }
            }
            return left
        }

        mutating func parseUnary() throws -> Value {
            if peek() == .op("-") { i += 1; let v = try parseUnary(); return Value(raw: -v.raw, percent: v.percent) }
            if peek() == .op("+") { i += 1; return try parseUnary() }
            return try parsePower()
        }

        mutating func parsePower() throws -> Value {
            let base = try parsePostfix()
            guard peek() == .op("^") else { return base }
            i += 1
            let exp = try parseUnary()      // right-associative: 2^3^2 = 2^9
            return Value(raw: pow(base.number, exp.number))
        }

        mutating func parsePostfix() throws -> Value {
            var v = try parsePrimary()
            while let t = peek() {
                if t == .op("%") {
                    i += 1
                    guard !v.percent else { throw CalcError.syntax }
                    v.percent = true
                } else if t == .op("!") {
                    i += 1
                    v = Value(raw: try Calculator.factorial(v.number))
                } else {
                    break
                }
            }
            return v
        }

        mutating func parsePrimary() throws -> Value {
            switch next() {
            case .number(let v, _)?: return Value(raw: v)
            case .constant(let v)?: return Value(raw: v)
            case .op("(")?:
                let v = try parseExpression()
                guard next() == .op(")") else { throw CalcError.syntax }
                return v
            case .function(let name)?:
                let arg = try parsePostfix().number
                return Value(raw: try Calculator.apply(name, arg))
            default:
                throw CalcError.syntax
            }
        }
    }

    static func factorial(_ v: Double) throws -> Double {
        guard v >= 0, v == v.rounded() else { throw CalcError.domain }
        guard v <= 170 else { throw CalcError.overflow }
        return v < 2 ? 1 : (2...Int(v)).reduce(1.0) { $0 * Double($1) }
    }

    static func apply(_ f: String, _ x: Double) throws -> Double {
        switch f {
        case "sqrt": guard x >= 0 else { throw CalcError.domain }; return x.squareRoot()
        case "cbrt": return cbrt(x)
        case "abs": return abs(x)
        case "round": return x.rounded()
        case "floor": return x.rounded(.down)
        case "ceil": return x.rounded(.up)
        case "ln": guard x > 0 else { throw CalcError.domain }; return log(x)
        case "log", "log10": guard x > 0 else { throw CalcError.domain }; return log10(x)
        case "log2": guard x > 0 else { throw CalcError.domain }; return log2(x)
        case "exp": return exp(x)
        case "sin": return sin(x)
        case "cos": return cos(x)
        case "tan": return tan(x)
        case "asin": guard abs(x) <= 1 else { throw CalcError.domain }; return asin(x)
        case "acos": guard abs(x) <= 1 else { throw CalcError.domain }; return acos(x)
        case "atan": return atan(x)
        default: throw CalcError.syntax
        }
    }
}

// MARK: Formatting

public enum PaletteFormat {
    /// For display: grouping, up to `fraction` decimals, float noise removed, scientific when huge
    /// or tiny.
    public static func number(_ v: Double, locale: Locale, grouping: Bool = true, fraction: Int = 10) -> String {
        if v == 0 { return "0" }
        let a = abs(v)
        let f = NumberFormatter()
        f.locale = locale
        if a >= 1e15 || a < 1e-7 {
            f.numberStyle = .scientific
            f.maximumSignificantDigits = 10
            f.usesSignificantDigits = true
            return f.string(from: NSNumber(value: v)) ?? "\(v)"
        }
        f.numberStyle = .decimal
        f.usesGroupingSeparator = grouping
        // 12 significant digits: 0.1 + 0.2 shows 0.3.
        let digitsLeft = a >= 1 ? Int(log10(a)) + 1 : 0
        f.maximumFractionDigits = max(0, min(fraction, 12 - digitsLeft))
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// "0xFF", "0b1010", "0o17"; nil when not a whole number that fits.
    public static func based(_ v: Double, _ base: NumberBase) -> String? {
        guard v == v.rounded(), abs(v) < 9_007_199_254_740_992 else { return nil }
        let n = Int64(v)
        let sign = n < 0 ? "-" : ""
        let m = n.magnitude
        switch base {
        case .hex: return sign + "0x" + String(m, radix: 16, uppercase: true)
        case .bin: return sign + "0b" + String(m, radix: 2)
        case .oct: return sign + "0o" + String(m, radix: 8)
        case .dec: return String(n)
        }
    }
}
