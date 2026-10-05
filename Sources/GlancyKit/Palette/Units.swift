import Foundation

// Unit conversion for the command bar: "5 km in mi", "70 f to c", "3 ore in min", "2 gb in mib".
// A number, a unit, then optionally a separator (in, to, into, as, a, ->, =) and a target unit;
// without a target the usual counterpart is used (km → mi, kg → lb, °C → °F).

public enum UnitCategory: String, Sendable, CaseIterable {
    case length, mass, temperature, volume, speed, data, time, area
}

public struct UnitDef: Sendable, Equatable {
    public let symbol: String
    public let category: UnitCategory
    /// Multiplier to the category's base unit (m, kg, l, m/s, byte, s, m²). Temperature: unused.
    public let factor: Double
    let aliases: [String]
    /// The counterpart shown when no target is typed.
    let counterpart: String?
}

public struct UnitConversion: Equatable, Sendable {
    public var value: Double
    public var from: UnitDef
    public var result: Double
    public var to: UnitDef
}

public enum Units {
    private static func u(_ symbol: String, _ c: UnitCategory, _ f: Double, _ aliases: [String], _ counterpart: String? = nil) -> UnitDef {
        UnitDef(symbol: symbol, category: c, factor: f, aliases: [symbol.lowercased()] + aliases, counterpart: counterpart)
    }

    public static let all: [UnitDef] = [
        // Length (m)
        u("mm", .length, 0.001, ["millimeter", "millimeters", "millimetre", "millimetres", "millimetro", "millimetri"], "in"),
        u("cm", .length, 0.01, ["centimeter", "centimeters", "centimetre", "centimetres", "centimetro", "centimetri"], "in"),
        u("m", .length, 1, ["meter", "meters", "metre", "metres", "metro", "metri"], "ft"),
        u("km", .length, 1000, ["kms", "kilometer", "kilometers", "kilometre", "kilometres", "chilometro", "chilometri"], "mi"),
        u("in", .length, 0.0254, ["inch", "inches", "pollice", "pollici", "\""], "cm"),
        u("ft", .length, 0.3048, ["foot", "feet", "piede", "piedi", "'"], "m"),
        u("yd", .length, 0.9144, ["yard", "yards", "iarda", "iarde"], "m"),
        u("mi", .length, 1609.344, ["mile", "miles", "miglio", "miglia"], "km"),
        u("nmi", .length, 1852, ["nautical mile", "nautical miles", "miglio nautico", "miglia nautiche"], "km"),
        // Mass (kg)
        u("mg", .mass, 1e-6, ["milligram", "milligrams", "milligrammo", "milligrammi"], "g"),
        u("g", .mass, 0.001, ["gr", "gram", "grams", "gramme", "grammes", "grammo", "grammi"], "oz"),
        u("kg", .mass, 1, ["kilo", "kilos", "kilogram", "kilograms", "chilo", "chili", "chilogrammo", "chilogrammi"], "lb"),
        u("t", .mass, 1000, ["tonne", "tonnes", "tonnellata", "tonnellate"], "lb"),
        u("oz", .mass, 0.028349523125, ["ounce", "ounces", "oncia", "once"], "g"),
        u("lb", .mass, 0.45359237, ["lbs", "pound", "pounds", "libbra", "libbre"], "kg"),
        u("st", .mass, 6.35029318, ["stone", "stones"], "kg"),
        // Temperature
        u("°C", .temperature, 1, ["c", "celsius", "centigradi", "gradi celsius", "gradi"], "°F"),
        u("°F", .temperature, 1, ["f", "fahrenheit", "gradi fahrenheit"], "°C"),
        u("K", .temperature, 1, ["kelvin"], "°C"),
        // Volume (l)
        u("ml", .volume, 0.001, ["milliliter", "milliliters", "millilitre", "millilitres", "millilitro", "millilitri"], "fl oz"),
        u("cl", .volume, 0.01, ["centiliter", "centiliters", "centilitro", "centilitri"], "fl oz"),
        u("dl", .volume, 0.1, ["deciliter", "deciliters", "decilitro", "decilitri"], "cup"),
        u("l", .volume, 1, ["liter", "liters", "litre", "litres", "litro", "litri", "lt"], "gal"),
        u("m³", .volume, 1000, ["m3", "cubic meter", "cubic meters", "metri cubi", "metro cubo"], "gal"),
        u("gal", .volume, 3.785411784, ["gallon", "gallons", "gallone", "galloni"], "l"),
        u("qt", .volume, 0.946352946, ["quart", "quarts"], "l"),
        u("pt", .volume, 0.473176473, ["pint", "pints", "pinta", "pinte"], "ml"),
        u("cup", .volume, 0.2365882365, ["cups", "tazza", "tazze"], "ml"),
        u("fl oz", .volume, 0.0295735295625, ["floz", "fluid ounce", "fluid ounces"], "ml"),
        u("tbsp", .volume, 0.01478676478125, ["tablespoon", "tablespoons", "cucchiaio", "cucchiai"], "ml"),
        u("tsp", .volume, 0.00492892159375, ["teaspoon", "teaspoons", "cucchiaino", "cucchiaini"], "ml"),
        // Speed (m/s)
        u("m/s", .speed, 1, ["mps", "meters per second", "metri al secondo"], "km/h"),
        u("km/h", .speed, 1 / 3.6, ["kmh", "kph", "kmph", "km orari", "chilometri orari", "kilometers per hour"], "mph"),
        u("mph", .speed, 0.44704, ["miles per hour", "miglia orarie"], "km/h"),
        u("kn", .speed, 1852.0 / 3600, ["kt", "knot", "knots", "nodo", "nodi"], "km/h"),
        u("ft/s", .speed, 0.3048, ["fps", "feet per second"], "m/s"),
        // Data (byte)
        u("bit", .data, 0.125, ["bits"], "B"),
        u("B", .data, 1, ["byte", "bytes"], "bit"),
        u("KB", .data, 1e3, ["kilobyte", "kilobytes"], "KiB"),
        u("MB", .data, 1e6, ["megabyte", "megabytes"], "MiB"),
        u("GB", .data, 1e9, ["gigabyte", "gigabytes", "giga"], "GiB"),
        u("TB", .data, 1e12, ["terabyte", "terabytes", "tera"], "TiB"),
        u("PB", .data, 1e15, ["petabyte", "petabytes"], "TB"),
        u("KiB", .data, 1024, ["kibibyte", "kibibytes"], "KB"),
        u("MiB", .data, 1_048_576, ["mebibyte", "mebibytes"], "MB"),
        u("GiB", .data, 1_073_741_824, ["gibibyte", "gibibytes"], "GB"),
        u("TiB", .data, 1_099_511_627_776, ["tebibyte", "tebibytes"], "TB"),
        u("Mbit", .data, 125_000, ["mbps", "megabit", "megabits"], "MB"),
        u("Gbit", .data, 125_000_000, ["gbps", "gigabit", "gigabits"], "GB"),
        // Time (s)
        u("ms", .time, 0.001, ["millisecond", "milliseconds", "millisecondo", "millisecondi"], "s"),
        u("s", .time, 1, ["sec", "secs", "second", "seconds", "secondo", "secondi"], "min"),
        u("min", .time, 60, ["mins", "minute", "minutes", "minuto", "minuti"], "s"),
        u("h", .time, 3600, ["hr", "hrs", "hour", "hours", "ora", "ore"], "min"),
        u("d", .time, 86_400, ["day", "days", "giorno", "giorni"], "h"),
        u("wk", .time, 604_800, ["week", "weeks", "settimana", "settimane"], "d"),
        u("mo", .time, 2_629_746, ["month", "months", "mese", "mesi"], "d"),
        u("yr", .time, 31_556_952, ["y", "year", "years", "anno", "anni"], "d"),
        // Area (m²)
        u("cm²", .area, 1e-4, ["cm2", "square centimeter", "square centimeters", "centimetri quadri"], "in²"),
        u("m²", .area, 1, ["m2", "mq", "sq m", "square meter", "square meters", "square metre", "square metres", "metri quadri", "metro quadro"], "ft²"),
        u("km²", .area, 1e6, ["km2", "square kilometer", "square kilometers", "chilometri quadri"], "mi²"),
        u("ha", .area, 1e4, ["hectare", "hectares", "ettaro", "ettari"], "acre"),
        u("acre", .area, 4046.8564224, ["acres", "acro", "acri"], "ha"),
        u("in²", .area, 0.00064516, ["in2", "sq in", "square inch", "square inches"], "cm²"),
        u("ft²", .area, 0.09290304, ["ft2", "sq ft", "square foot", "square feet", "piedi quadri"], "m²"),
        u("mi²", .area, 2_589_988.110336, ["mi2", "sq mi", "square mile", "square miles"], "km²"),
    ]

    /// Alias (lowercased) → unit. Case-insensitive: "mb" is a megabyte; bits are spelled "Mbit".
    static let byAlias: [String: UnitDef] = {
        var map: [String: UnitDef] = [:]
        for unit in all { for a in unit.aliases where map[a] == nil { map[a] = unit } }
        return map
    }()

    public static func unit(_ s: String) -> UnitDef? {
        var key = s.lowercased().trimmingCharacters(in: .whitespaces)
        key = key.replacingOccurrences(of: "²", with: "2").replacingOccurrences(of: "³", with: "3")
        if let u = byAlias[key] { return u }
        // "°c", "° f", "degrees f", "gradi c".
        for prefix in ["°", "degrees ", "degree ", "deg ", "gradi "] where key.hasPrefix(prefix) {
            if let u = byAlias[String(key.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)], u.category == .temperature { return u }
        }
        return nil
    }

    static let separators = [" in ", " to ", " into ", " as ", " a ", " = ", " => "]

    /// nil when the input isn't a conversion.
    public static func parse(_ input: String, decimalComma: Bool = false) -> UnitConversion? {
        guard let (value, rest) = leadingNumber(input, decimalComma: decimalComma), !rest.isEmpty else { return nil }
        let text = " " + rest.replacingOccurrences(of: "->", with: " to ").replacingOccurrences(of: "→", with: " to ") + " "
        // The first separator whose left side is a unit and right side a unit of the same kind.
        for sep in separators {
            var search = text.startIndex..<text.endIndex
            while let r = text.range(of: sep, range: search) {
                let left = String(text[..<r.lowerBound]), right = String(text[r.upperBound...])
                if let from = unit(left), let to = unit(right), from.category == to.category {
                    return UnitConversion(value: value, from: from, result: convert(value, from, to), to: to)
                }
                search = text.index(after: r.lowerBound)..<text.endIndex
            }
        }
        guard let from = unit(rest), let symbol = from.counterpart, let to = all.first(where: { $0.symbol == symbol }) else { return nil }
        return UnitConversion(value: value, from: from, result: convert(value, from, to), to: to)
    }

    public static func convert(_ v: Double, _ from: UnitDef, _ to: UnitDef) -> Double {
        guard from.category == .temperature else { return v * from.factor / to.factor }
        let kelvin: Double = switch from.symbol {
        case "°C": v + 273.15
        case "°F": (v - 32) * 5 / 9 + 273.15
        default: v
        }
        return switch to.symbol {
        case "°C": kelvin - 273.15
        case "°F": (kelvin - 273.15) * 9 / 5 + 32
        default: kelvin
        }
    }

    /// "5 km…" → (5, "km…"); also "5km", "-40 f", "1,5 l". The rest is lowercased and trimmed.
    static func leadingNumber(_ input: String, decimalComma: Bool) -> (Double, String)? {
        let s = input.trimmingCharacters(in: .whitespaces)
        var end = s.startIndex
        var raw = ""
        if end < s.endIndex, s[end] == "-" || s[end] == "+" { raw.append(s[end]); end = s.index(after: end) }
        var digits = false
        while end < s.endIndex, s[end].isNumber || s[end] == "." || s[end] == "," {
            if s[end].isNumber { digits = true }
            raw.append(s[end]); end = s.index(after: end)
        }
        guard digits else { return nil }
        let sign: Double = raw.hasPrefix("-") ? -1 : 1
        let body = raw.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        guard let v = Calculator.parseNumber(body, decimalComma: decimalComma) else { return nil }
        return (sign * v, String(s[end...]).trimmingCharacters(in: .whitespaces).lowercased())
    }
}
