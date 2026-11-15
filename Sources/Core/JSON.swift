import Foundation

/// Valeur JSON quelconque : les réponses du moteur (ytmusicapi) changent de forme selon la page, comme dans la PWA.
enum JSON: Codable, Hashable {
    case null, bool(Bool), num(Double), str(String), arr([JSON]), obj([String: JSON])

    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .num(n) }
        else if let s = try? c.decode(String.self) { self = .str(s) }
        else if let a = try? c.decode([JSON].self) { self = .arr(a) }
        else { self = .obj(try c.decode([String: JSON].self)) }
    }
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .num(let n): try c.encode(n)
        case .str(let s): try c.encode(s)
        case .arr(let a): try c.encode(a)
        case .obj(let o): try c.encode(o)
        }
    }

    subscript(_ k: String) -> JSON { if case .obj(let o) = self { return o[k] ?? .null }; return .null }
    subscript(_ i: Int) -> JSON { if case .arr(let a) = self, a.indices.contains(i) { return a[i] }; return .null }

    var string: String? {
        switch self { case .str(let s): s; case .num(let n): n == n.rounded() ? String(Int(n)) : String(n); default: nil }
    }
    var double: Double? {
        switch self { case .num(let n): n; case .str(let s): Double(s); case .bool(let b): b ? 1 : 0; default: nil }
    }
    var int: Int? { double.map { Int($0) } }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSON] { if case .arr(let a) = self { return a }; return [] }
    var object: [String: JSON] { if case .obj(let o) = self { return o }; return [:] }
    var isNull: Bool { if case .null = self { return true }; return false }
    var exists: Bool { !isNull }
    var truthy: Bool {
        switch self {
        case .null: false
        case .bool(let b): b
        case .num(let n): n != 0
        case .str(let s): !s.isEmpty
        case .arr, .obj: true
        }
    }

    static func from(_ v: Any?) -> JSON {
        switch v {
        case nil: return .null
        case let j as JSON: return j
        case let b as Bool: return .bool(b)
        case let i as Int: return .num(Double(i))
        case let d as Double: return .num(d)
        case let s as String: return .str(s)
        case let a as [Any?]: return .arr(a.map(from))
        case let o as [String: Any?]: return .obj(o.mapValues(from))
        default: return .null
        }
    }
    var data: Data { (try? JSONEncoder().encode(self)) ?? Data("null".utf8) }
    static func parse(_ d: Data) -> JSON? { try? JSONDecoder().decode(JSON.self, from: d) }

    func decode<T: Decodable>(_: T.Type) -> T? { try? JSONDecoder().decode(T.self, from: data) }
    static func encode<T: Encodable>(_ v: T) -> JSON { (try? JSONEncoder().encode(v)).flatMap(parse) ?? .null }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral {
    init(stringLiteral v: String) { self = .str(v) }
    init(integerLiteral v: Int) { self = .num(Double(v)) }
    init(booleanLiteral v: Bool) { self = .bool(v) }
    init(dictionaryLiteral els: (String, JSON)...) { self = .obj(Dictionary(els, uniquingKeysWith: { $1 })) }
    init(arrayLiteral els: JSON...) { self = .arr(els) }
    init(nilLiteral: ()) { self = .null }
}
