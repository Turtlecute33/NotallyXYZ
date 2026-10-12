import CryptoKit
import Foundation

public enum SealError: Error {
    case invalid
    case io
}

/// Sealed format of PROTOCOL.md §4: chunked AES-256-GCM with a per-message HKDF subkey and
/// padmé length padding. Works on streams so that large attachments never sit in memory twice.
public enum Seal {
    static let version: UInt8 = 0x01
    static let saltSize = 32
    static let chunkSize = 65536
    static let tagSize = 16
    static let minPadded = 256

    public static func padme(_ l: UInt64) -> UInt64 {
        if l < 2 { return l }
        let e = UInt64(63 - l.leadingZeroBitCount)
        let s = UInt64(63 - e.leadingZeroBitCount) + 1
        let mask = (UInt64(1) << (e - s)) - 1
        return (l + mask) & ~mask
    }

    public static func paddedSize(_ n: Int) -> Int {
        max(minPadded, Int(padme(UInt64(8 + n))))
    }

    public static func sealedSize(_ n: Int) -> Int {
        let t = paddedSize(n)
        return 1 + saltSize + t + tagSize * ((t + chunkSize - 1) / chunkSize)
    }

    public static func ad(_ kind: String, _ id: String) -> Data {
        Data("notallyxyz/v1|\(kind)|\(id)".utf8)
    }

    static func nonce(_ i: Int, last: Bool) -> AES.GCM.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[7] = UInt8((i >> 24) & 0xFF)
        bytes[8] = UInt8((i >> 16) & 0xFF)
        bytes[9] = UInt8((i >> 8) & 0xFF)
        bytes[10] = UInt8(i & 0xFF)
        bytes[11] = last ? 1 : 0
        return try! AES.GCM.Nonce(data: bytes)
    }

    static func subkey(_ key: SymmetricKey, salt: Data) -> SymmetricKey {
        SyncKeys.derive(key, salt: salt, info: "notallyxyz/v1/seal")
    }

    static func randomSalt() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    // MARK: Streaming core

    /// Seals `length` bytes delivered by `read` and hands the output pieces to `write`.
    static func sealStream(
        length: Int, key: SymmetricKey, ad: Data, salt: Data? = nil,
        read: (Int) throws -> Data, write: (Data) throws -> Void
    ) throws {
        let salt = salt ?? randomSalt()
        precondition(salt.count == saltSize)
        let total = paddedSize(length)
        let sub = subkey(key, salt: salt)
        try write(Data([version]) + salt)

        var lengthPrefix = Data(count: 8)
        for i in 0..<8 { lengthPrefix[i] = UInt8((UInt64(length) >> (56 - 8 * UInt64(i))) & 0xFF) }
        var pending = lengthPrefix
        var remainingSource = length
        let chunks = (total + chunkSize - 1) / chunkSize
        for i in 0..<chunks {
            let size = min(chunkSize, total - i * chunkSize)
            while pending.count < size && remainingSource > 0 {
                let part = try read(min(remainingSource, size - pending.count))
                if part.isEmpty { throw SealError.io }
                pending.append(part)
                remainingSource -= part.count
            }
            var piece = pending.prefix(size)
            pending = pending.dropFirst(size)
            if piece.count < size { piece.append(Data(count: size - piece.count)) }
            let box = try AES.GCM.seal(piece, using: sub, nonce: nonce(i, last: i == chunks - 1), authenticating: ad)
            try write(box.ciphertext + box.tag)
        }
    }

    /// Opens a sealed stream of `sealedLength` bytes. Plaintext goes to `write`.
    static func openStream(
        sealedLength: Int, key: SymmetricKey, ad: Data,
        read: (Int) throws -> Data, write: (Data) throws -> Void
    ) throws {
        guard sealedLength >= 1 + saltSize + tagSize + 1 else { throw SealError.invalid }
        let header = try read(1 + saltSize)
        guard header.count == 1 + saltSize, header.first == version else { throw SealError.invalid }
        let sub = subkey(key, salt: header.dropFirst())
        var remaining = sealedLength - 1 - saltSize
        var plainLength: UInt64?
        var written: UInt64 = 0
        var i = 0
        while remaining > 0 {
            let size = min(remaining, chunkSize + tagSize)
            guard size > tagSize else { throw SealError.invalid }
            let piece = try read(size)
            guard piece.count == size else { throw SealError.invalid }
            remaining -= size
            let box = try AES.GCM.SealedBox(
                nonce: nonce(i, last: remaining == 0),
                ciphertext: piece.prefix(size - tagSize), tag: piece.suffix(tagSize))
            guard var plain = try? AES.GCM.open(box, using: sub, authenticating: ad) else {
                throw SealError.invalid
            }
            if plainLength == nil {
                guard plain.count >= 8 else { throw SealError.invalid }
                plainLength = plain.prefix(8).reduce(0) { ($0 << 8) | UInt64($1) }
                plain = plain.dropFirst(8)
            }
            let take = Int(min(UInt64(plain.count), plainLength! - written))
            if take > 0 { try write(plain.prefix(take)) }
            written += UInt64(take)
            guard plain.dropFirst(take).allSatisfy({ $0 == 0 }) else { throw SealError.invalid }
            i += 1
        }
        guard let n = plainLength, written == n else { throw SealError.invalid }
    }

    // MARK: In memory

    public static func seal(_ message: Data, key: SymmetricKey, ad: Data, salt: Data? = nil) throws -> Data {
        var out = Data(capacity: sealedSize(message.count))
        var offset = message.startIndex
        try sealStream(length: message.count, key: key, ad: ad, salt: salt, read: { n in
            let end = message.index(offset, offsetBy: n)
            defer { offset = end }
            return message[offset..<end]
        }, write: { out.append($0) })
        return out
    }

    public static func open(_ sealed: Data, key: SymmetricKey, ad: Data) throws -> Data {
        var out = Data()
        var offset = sealed.startIndex
        try openStream(sealedLength: sealed.count, key: key, ad: ad, read: { n in
            let end = sealed.index(offset, offsetBy: min(n, sealed.endIndex - offset))
            defer { offset = end }
            return sealed[offset..<end]
        }, write: { out.append($0) })
        return out
    }

    // MARK: Files

    public static func sealFile(from source: URL, to target: URL, key: SymmetricKey, ad: Data) throws {
        let length = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int ?? 0
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try createPrivateFile(target)
        defer { try? output.close() }
        try sealStream(length: length, key: key, ad: ad, read: { n in
            try input.read(upToCount: n) ?? Data()
        }, write: { try output.write(contentsOf: $0) })
    }

    public static func openFile(from source: URL, to target: URL, key: SymmetricKey, ad: Data) throws {
        let length = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int ?? 0
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try createPrivateFile(target)
        defer { try? output.close() }
        do {
            try openStream(sealedLength: length, key: key, ad: ad, read: { n in
                try input.read(upToCount: n) ?? Data()
            }, write: { try output.write(contentsOf: $0) })
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    static func createPrivateFile(_ url: URL) throws -> FileHandle {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw SealError.io
        }
        return try FileHandle(forWritingTo: url)
    }
}
