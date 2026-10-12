import CryptoKit
import Foundation

public enum KeyError: Error, Equatable {
    case wrongLength
    case invalidCharacters
    case checksumMismatch
}

/// The 32-byte sync key and the keys derived from it (PROTOCOL.md §1–3).
public struct SyncKeys: Sendable {
    public let raw: Data
    public let authToken: Data
    public let encKey: SymmetricKey
    public let idKey: SymmetricKey

    public init(raw: Data) {
        precondition(raw.count == 32, "sync key must be 32 bytes")
        self.raw = raw
        let ikm = SymmetricKey(data: raw)
        authToken = Self.derive(ikm, info: "notallyxyz/v1/auth").withUnsafeBytes { Data($0) }
        encKey = Self.derive(ikm, info: "notallyxyz/v1/enc")
        idKey = Self.derive(ikm, info: "notallyxyz/v1/id")
    }

    public static func generate() -> SyncKeys {
        SyncKeys(raw: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    static func derive(_ ikm: SymmetricKey, salt: Data = Data(), info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt, info: Data(info.utf8), outputByteCount: 32)
    }

    /// Bearer token: base64url without padding.
    public var bearer: String { authToken.base64URLEncodedString() }

    public func labelID(_ value: String) -> String { hmacID("label:" + value) }
    public func blobID(_ localName: String) -> String { hmacID("blob:" + localName) }

    private func hmacID(_ message: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: idKey)
        return Data(mac).prefix(16).hexString
    }

    // MARK: Display form

    private static func checksum(_ key: Data) -> Data {
        Data(SHA256.hash(data: Data("notallyxyz/v1/key-check".utf8) + key)).prefix(3)
    }

    /// 56 Crockford base32 characters in 14 groups of 4.
    public var display: String {
        let encoded = Base32.encode(raw + Self.checksum(raw))
        var groups: [String] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: 4, limitedBy: encoded.endIndex) ?? encoded.endIndex
            groups.append(String(encoded[index..<end]))
            index = end
        }
        return groups.joined(separator: "-")
    }

    public static func parse(_ text: String) throws -> SyncKeys {
        var cleaned = ""
        for ch in text.uppercased() where !" -\n\t\r".contains(ch) {
            switch ch {
            case "O": cleaned.append("0")
            case "I", "L": cleaned.append("1")
            default: cleaned.append(ch)
            }
        }
        guard cleaned.count == 56 else { throw KeyError.wrongLength }
        guard let raw = Base32.decode(cleaned), raw.count == 35 else {
            throw KeyError.invalidCharacters
        }
        let key = raw.prefix(32)
        guard checksum(Data(key)) == raw.suffix(3) else { throw KeyError.checksumMismatch }
        return SyncKeys(raw: Data(key))
    }
}

/// Crockford alphabet, RFC 4648 bit order, no padding.
enum Base32 {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func encode(_ data: Data) -> String {
        var out = ""
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    static func decode(_ text: String) -> Data? {
        var lookup = [Character: Int]()
        for (i, c) in alphabet.enumerated() { lookup[c] = i }
        var out = Data()
        var buffer = 0
        var bits = 0
        for ch in text {
            guard let value = lookup[ch] else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> (bits - 8)) & 0xFF))
                bits -= 8
            }
            buffer &= (1 << bits) - 1
        }
        return out
    }
}

extension Data {
    public var hexString: String { map { String(format: "%02x", $0) }.joined() }

    public init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }

    public func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 16 random bytes as 32 hex characters (note ids).
    public static func randomID() -> String {
        SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }.hexString
    }
}
