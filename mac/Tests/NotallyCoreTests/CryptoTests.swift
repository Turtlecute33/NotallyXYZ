import CryptoKit
import Foundation
import Testing

@testable import NotallyCore

struct Vectors: Decodable {
    struct SealVector: Decodable {
        let name, kind, id, salt, plain, sealed: String
    }
    let syncKey, display, authTokenBase64Url, encKey, idKey: String
    let labelIds, blobIds: [String: String]
    let padme: [String: UInt64]
    let sealedSize: [String: Int]
    let seal: [SealVector]

    static let shared: Vectors = {
        let url = URL(filePath: "../../../server/testvectors.json", relativeTo: URL(filePath: #filePath))
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()
}

private func keyData(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

@Suite struct CryptoTests {
    let v = Vectors.shared

    @Test func displayAndParse() throws {
        let keys = SyncKeys(raw: Data(hex: v.syncKey)!)
        #expect(keys.display == v.display)
        let parsed = try SyncKeys.parse(" " + v.display.lowercased().replacingOccurrences(of: "0", with: "o") + "\n")
        #expect(parsed.raw == keys.raw)
        let compact = try SyncKeys.parse(v.display.replacingOccurrences(of: "-", with: ""))
        #expect(compact.raw == keys.raw)
    }

    @Test func typoRejected() {
        var chars = Array(v.display)
        chars[5] = chars[5] == "A" ? "B" : "A"
        #expect(throws: KeyError.checksumMismatch) { try SyncKeys.parse(String(chars)) }
        #expect(throws: KeyError.wrongLength) { try SyncKeys.parse(String(v.display.dropLast(2))) }
        #expect(throws: KeyError.invalidCharacters) {
            try SyncKeys.parse("U" + String(v.display.dropFirst()))
        }
    }

    @Test func generatedKeysRoundTrip() throws {
        for _ in 0..<20 {
            let keys = SyncKeys.generate()
            #expect(try SyncKeys.parse(keys.display).raw == keys.raw)
        }
    }

    @Test func derivedKeys() {
        let keys = SyncKeys(raw: Data(hex: v.syncKey)!)
        #expect(keys.bearer == v.authTokenBase64Url)
        #expect(keyData(keys.encKey).hexString == v.encKey)
        #expect(keyData(keys.idKey).hexString == v.idKey)
    }

    @Test func ids() {
        let keys = SyncKeys(raw: Data(hex: v.syncKey)!)
        for (label, id) in v.labelIds { #expect(keys.labelID(label) == id) }
        for (name, id) in v.blobIds { #expect(keys.blobID(name) == id) }
    }

    @Test func padmeAndSizes() {
        for (n, want) in v.padme { #expect(Seal.padme(UInt64(n)!) == want) }
        for (n, want) in v.sealedSize { #expect(Seal.sealedSize(Int(n)!) == want) }
    }

    @Test func vectorsOpenAndReseal() throws {
        let enc = SymmetricKey(data: Data(hex: v.encKey)!)
        #expect(v.seal.count == 5)
        for s in v.seal {
            let ad = Seal.ad(s.kind, s.id)
            let sealed = Data(hex: s.sealed)!
            let plain = Data(hex: s.plain)!
            #expect(try Seal.open(sealed, key: enc, ad: ad) == plain, "\(s.name)")
            #expect(try Seal.seal(plain, key: enc, ad: ad, salt: Data(hex: s.salt)!) == sealed, "\(s.name)")
            #expect(throws: SealError.self) { try Seal.open(sealed, key: enc, ad: Seal.ad("other", s.id)) }
            var tampered = sealed
            tampered[tampered.count - 20] ^= 1
            #expect(throws: SealError.self) { try Seal.open(tampered, key: enc, ad: ad) }
            if sealed.count > 1 + 32 + 65552 {
                #expect(throws: SealError.self) { try Seal.open(sealed.prefix(1 + 32 + 65552), key: enc, ad: ad) }
            }
        }
    }

    @Test func fileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        for n in [0, 5, 65528, 65529, 300_000] {
            let data = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 7) })
            let plain = dir.appendingPathComponent("p"), sealed = dir.appendingPathComponent("s"), back = dir.appendingPathComponent("b")
            try data.write(to: plain)
            try Seal.sealFile(from: plain, to: sealed, key: key, ad: Seal.ad("blob", "x"))
            #expect(try Data(contentsOf: sealed).count == Seal.sealedSize(n))
            try Seal.openFile(from: sealed, to: back, key: key, ad: Seal.ad("blob", "x"))
            #expect(try Data(contentsOf: back) == data)
            #expect(try Seal.open(Data(contentsOf: sealed), key: key, ad: Seal.ad("blob", "x")) == data)
        }
    }
}
