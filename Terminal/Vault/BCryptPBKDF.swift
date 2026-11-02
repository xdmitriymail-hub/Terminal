import Foundation
import CryptoKit

/// Pure-Swift Blowfish + bcrypt_pbkdf, ported from OpenBSD blf.c/bcrypt_pbkdf.c.
/// Used to decrypt passphrase-protected OpenSSH private keys.
struct Blowfish {
    private(set) var P = BlowfishTables.initP
    private(set) var S = BlowfishTables.initS

    @inline(__always)
    private func f(_ x: UInt32) -> UInt32 {
        let a = Int(x >> 24)
        let b = Int((x >> 16) & 0xff)
        let c = Int((x >> 8) & 0xff)
        let d = Int(x & 0xff)
        return ((S[a] &+ S[256 + b]) ^ S[512 + c]) &+ S[768 + d]
    }

    mutating func encipher(_ xl: inout UInt32, _ xr: inout UInt32) {
        var l = xl
        var r = xr
        for i in 0..<16 {
            l ^= P[i]
            r ^= f(l)
            swap(&l, &r)
        }
        swap(&l, &r)
        r ^= P[16]
        l ^= P[17]
        xl = l
        xr = r
    }

    private static func stream2word(_ data: [UInt8], _ offset: inout Int) -> UInt32 {
        var word: UInt32 = 0
        for _ in 0..<4 {
            word = (word << 8) | UInt32(data[offset])
            offset = (offset + 1) % data.count
        }
        return word
    }

    /// ExpandKey: P ^= key stream, then encrypt-mix through P and S with data stream.
    mutating func expandState(data: [UInt8], key: [UInt8]) {
        var j = 0
        for i in 0..<18 {
            P[i] ^= Self.stream2word(key, &j)
        }
        j = 0
        var l: UInt32 = 0, r: UInt32 = 0
        for i in stride(from: 0, to: 18, by: 2) {
            l ^= Self.stream2word(data, &j)
            r ^= Self.stream2word(data, &j)
            encipher(&l, &r)
            P[i] = l; P[i + 1] = r
        }
        for box in 0..<4 {
            for k in stride(from: 0, to: 256, by: 2) {
                l ^= Self.stream2word(data, &j)
                r ^= Self.stream2word(data, &j)
                encipher(&l, &r)
                S[box * 256 + k] = l; S[box * 256 + k + 1] = r
            }
        }
    }

    mutating func expand0State(key: [UInt8]) {
        var j = 0
        for i in 0..<18 {
            P[i] ^= Self.stream2word(key, &j)
        }
        var l: UInt32 = 0, r: UInt32 = 0
        for i in stride(from: 0, to: 18, by: 2) {
            encipher(&l, &r)
            P[i] = l; P[i + 1] = r
        }
        for box in 0..<4 {
            for k in stride(from: 0, to: 256, by: 2) {
                encipher(&l, &r)
                S[box * 256 + k] = l; S[box * 256 + k + 1] = r
            }
        }
    }
}

enum BCryptPBKDF {
    /// "OxychromaticBlowfishSwatDynamite" as big-endian u32 words.
    private static let bcryptCiphertext: [UInt32] = [
        0x4f787963, 0x68726f6d, 0x61746963, 0x426c6f77,
        0x66697368, 0x53776174, 0x44796e61, 0x6d697465
    ]

    /// bcrypt_hash: expandstate(salt, sha2pass) then alternate
    /// expand0state(salt)/expand0state(pass) 64×, then 64 encipher
    /// rounds over cdata. Output is little-endian per word.
    static func hash(sha2pass: [UInt8], sha2salt: [UInt8]) -> [UInt8] {
        var state = Blowfish()
        var cdata = bcryptCiphertext

        state.expandState(data: sha2salt, key: sha2pass)
        for _ in 0..<64 {
            state.expand0State(key: sha2salt)
            state.expand0State(key: sha2pass)
        }
        for _ in 0..<64 {
            for j in 0..<4 {
                var l = cdata[j * 2], r = cdata[j * 2 + 1]
                state.encipher(&l, &r)
                cdata[j * 2] = l
                cdata[j * 2 + 1] = r
            }
        }
        var out = [UInt8]()
        out.reserveCapacity(32)
        for word in cdata {
            out.append(UInt8(word & 0xff))
            out.append(UInt8(word >> 8 & 0xff))
            out.append(UInt8(word >> 16 & 0xff))
            out.append(UInt8(word >> 24 & 0xff))
        }
        return out
    }

    /// OpenBSD bcrypt_pbkdf: blocks are interleaved across the output —
    /// byte i of block c lands at key[i * stride + (c - 1)].
    static func pbkdf(password: Data, salt: Data, keyLength: Int, rounds: Int) -> Data {
        // The `false` check can never fire — the try! cannot throw.
        // swiftlint:disable-next-line force_try
        try! pbkdf(password: password, salt: salt, keyLength: keyLength, rounds: rounds, isCancelled: { false })
    }

    /// Cooperatively-cancellable variant: `isCancelled` is polled once
    /// per bcrypt round (and once per output block), throwing
    /// `CancellationError` so a detached UI task unwinds promptly
    /// instead of hashing for seconds after the user navigated away.
    static func pbkdf(password: Data, salt: Data, keyLength: Int, rounds: Int, isCancelled: () -> Bool) throws -> Data {
        guard keyLength > 0, rounds > 0 else { return Data() }
        if isCancelled() { throw CancellationError() }
        let stride = (keyLength + 31) / 32
        let amount = (keyLength + stride - 1) / stride
        var key = Data(repeating: 0, count: keyLength)
        let sha2pass = [UInt8](SHA512.hash(data: password))

        var remaining = keyLength
        var count: UInt32 = 1
        while remaining > 0 {
            if isCancelled() { throw CancellationError() }
            var countsalt = Data(salt)
            var bigCount = count.bigEndian
            countsalt.append(Data(bytes: &bigCount, count: 4))
            var sha2salt = Data(SHA512.hash(data: countsalt))

            var tmp = hash(sha2pass: sha2pass, sha2salt: [UInt8](sha2salt))
            var block = tmp
            for _ in 1..<rounds {
                if isCancelled() { throw CancellationError() }
                sha2salt = Data(SHA512.hash(data: tmp))
                tmp = hash(sha2pass: sha2pass, sha2salt: [UInt8](sha2salt))
                for j in 0..<32 { block[j] ^= tmp[j] }
            }

            var written = 0
            for i in 0..<amount {
                let dest = i * stride + Int(count - 1)
                guard dest < keyLength else { break }
                key[dest] = block[i]
                written += 1
            }
            remaining -= written
            count += 1
        }
        return key
    }
}
