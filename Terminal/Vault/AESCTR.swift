import Foundation
import CommonCrypto

enum AESCTRError: Error {
    case cryptoFailed
}

/// AES-CTR implemented over CommonCrypto AES-ECB block encryption.
enum AESCTR {
    static func crypt(key: Data, iv: Data, data: Data) throws -> Data {
        var counter = [UInt8](iv)
        var out = Data()
        out.reserveCapacity(data.count)

        var block = [UInt8](repeating: 0, count: 16)
        var blockUsed = 0

        func nextKeystreamByte() throws -> UInt8 {
            if blockUsed == 16 {
                var numMoved = 0
                var encrypted = [UInt8](repeating: 0, count: 16)
                let status = key.withUnsafeBytes { keyPtr in
                    counter.withUnsafeBytes { ctrPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionECBMode),
                            keyPtr.baseAddress, key.count,
                            nil,
                            ctrPtr.baseAddress, 16,
                            &encrypted, 16,
                            &numMoved
                        )
                    }
                }
                guard status == kCCSuccess else { throw AESCTRError.cryptoFailed }
                block = encrypted
                blockUsed = 0
                // increment counter as a 128-bit big-endian integer
                for i in stride(from: 15, through: 0, by: -1) {
                    counter[i] &+= 1
                    if counter[i] != 0 { break }
                }
            }
            defer { blockUsed += 1 }
            return block[blockUsed]
        }

        for byte in data {
            out.append(byte ^ (try nextKeystreamByte()))
        }
        return out
    }
}
