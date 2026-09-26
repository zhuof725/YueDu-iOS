import Foundation
import CommonCrypto
import CryptoKit
import JavaScriptCore

enum Crypto {
    /// 书源里 key/iv 可能是字符串，也可能是字节数组
    static func bytes(_ v: Any) -> Data {
        if let s = v as? String { return Data(s.utf8) }
        if let a = v as? [Any] { return Data(a.compactMap { ($0 as? NSNumber).map { UInt8(truncatingIfNeeded: $0.intValue) } }) }
        if let d = v as? Data { return d }
        return Data("\(v)".utf8)
    }

    static func hmac(_ algo: String, _ key: String, _ data: String) -> Data {
        let k = SymmetricKey(data: Data(key.utf8))
        let d = Data(data.utf8)
        switch algo.lowercased().replacingOccurrences(of: "-", with: "") {
        case "hmacmd5", "md5": return Data(HMAC<Insecure.MD5>.authenticationCode(for: d, using: k))
        case "hmacsha1", "sha1": return Data(HMAC<Insecure.SHA1>.authenticationCode(for: d, using: k))
        case "hmacsha512", "sha512": return Data(HMAC<SHA512>.authenticationCode(for: d, using: k))
        case "hmacsha384", "sha384": return Data(HMAC<SHA384>.authenticationCode(for: d, using: k))
        default: return Data(HMAC<SHA256>.authenticationCode(for: d, using: k))
        }
    }

    static func digest(_ algo: String, _ d: Data) -> Data {
        switch algo.lowercased().replacingOccurrences(of: "-", with: "") {
        case "md5": return Data(Insecure.MD5.hash(data: d))
        case "sha1": return Data(Insecure.SHA1.hash(data: d))
        case "sha512": return Data(SHA512.hash(data: d))
        case "sha384": return Data(SHA384.hash(data: d))
        default: return Data(SHA256.hash(data: d))
        }
    }

    /// AES / DES / 3DES，模式 ECB/CBC，填充 PKCS5/PKCS7/NoPadding
    static func symmetric(_ transformation: String, key: Data, iv: Data?, data: Data, encrypt: Bool) -> Data? {
        let parts = transformation.uppercased().split(separator: "/").map(String.init)
        let algoName = parts.first ?? "AES"
        let mode = parts.count > 1 ? parts[1] : "ECB"
        let padding = parts.count > 2 ? parts[2] : "PKCS5PADDING"
        var algo = CCAlgorithm(kCCAlgorithmAES)
        var block = kCCBlockSizeAES128
        if algoName == "DES" { algo = CCAlgorithm(kCCAlgorithmDES); block = kCCBlockSizeDES }
        else if algoName.hasPrefix("DESEDE") || algoName == "3DES" || algoName == "TRIPLEDES" {
            algo = CCAlgorithm(kCCAlgorithm3DES); block = kCCBlockSize3DES
        }
        var options = CCOptions(0)
        if !padding.contains("NOPADDING") { options |= CCOptions(kCCOptionPKCS7Padding) }
        if mode == "ECB" { options |= CCOptions(kCCOptionECBMode) }
        var ivData = iv ?? Data(count: block)
        if ivData.count < block { ivData.append(Data(count: block - ivData.count)) }
        var input = data
        if padding.contains("NOPADDING") && encrypt && input.count % block != 0 {
            input.append(Data(count: block - input.count % block))
        }
        var out = Data(count: input.count + block)
        var outLen = 0
        let outCap = out.count
        let status = out.withUnsafeMutableBytes { o in
            input.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    ivData.withUnsafeBytes { v in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), algo, options,
                                k.baseAddress, key.count, mode == "ECB" ? nil : v.baseAddress,
                                i.baseAddress, input.count, o.baseAddress, outCap, &outLen)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLen
        return out
    }

    /// 输入可能是 base64 / hex / 原文
    static func decodeInput(_ s: String) -> Data {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count % 2 == 0, t.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil, t.count >= 16 {
            var d = Data(); var i = t.startIndex
            while i < t.endIndex { let j = t.index(i, offsetBy: 2); d.append(UInt8(t[i..<j], radix: 16)!); i = j }
            return d
        }
        if let d = Data(base64Encoded: t, options: .ignoreUnknownCharacters) { return d }
        return Data(t.utf8)
    }
}

@objc protocol SymmetricCryptoBridgeExports: JSExport {
    func decrypt(_ data: Any) -> [Int]
    func decryptStr(_ data: Any) -> String
    func encrypt(_ data: Any) -> [Int]
    func encryptBase64(_ data: Any) -> String
    func encryptHex(_ data: Any) -> String
}

@objc final class SymmetricCryptoBridge: NSObject, SymmetricCryptoBridgeExports {
    let t: String, key: Data, iv: Data?
    init(_ t: String, _ key: Data, _ iv: Data?) { self.t = t; self.key = key; self.iv = iv }

    private func input(_ v: Any, forDecrypt: Bool) -> Data {
        if let s = v as? String { return forDecrypt ? Crypto.decodeInput(s) : Data(s.utf8) }
        return Crypto.bytes(v)
    }
    private func dec(_ v: Any) -> Data { Crypto.symmetric(t, key: key, iv: iv, data: input(v, forDecrypt: true), encrypt: false) ?? Data() }
    private func enc(_ v: Any) -> Data { Crypto.symmetric(t, key: key, iv: iv, data: input(v, forDecrypt: false), encrypt: true) ?? Data() }

    func decrypt(_ data: Any) -> [Int] { dec(data).map { Int(Int8(bitPattern: $0)) } }
    func decryptStr(_ data: Any) -> String { let d = dec(data); return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self) }
    func encrypt(_ data: Any) -> [Int] { enc(data).map { Int(Int8(bitPattern: $0)) } }
    func encryptBase64(_ data: Any) -> String { enc(data).base64EncodedString() }
    func encryptHex(_ data: Any) -> String { enc(data).map { String(format: "%02x", $0) }.joined() }
}
