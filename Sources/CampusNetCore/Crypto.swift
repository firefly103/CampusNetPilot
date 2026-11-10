import Foundation

// MARK: - 纯 Swift 摘要实现
//
// 不依赖 CryptoKit / CommonCrypto：核心逻辑因此可以在任意工具链（包括 Linux CI）
// 上编译与测试，便于在没有 macOS 真机时验证 SRun 载荷是否与参考实现一致。

public enum Digest {
    // MARK: MD5

    private static let md5Shift: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
    ]

    private static let md5K: [UInt32] = [
        0xd76a_a478, 0xe8c7_b756, 0x2420_70db, 0xc1bd_ceee,
        0xf57c_0faf, 0x4787_c62a, 0xa830_4613, 0xfd46_9501,
        0x6980_98d8, 0x8b44_f7af, 0xffff_5bb1, 0x895c_d7be,
        0x6b90_1122, 0xfd98_7193, 0xa679_438e, 0x49b4_0821,
        0xf61e_2562, 0xc040_b340, 0x265e_5a51, 0xe9b6_c7aa,
        0xd62f_105d, 0x0244_1453, 0xd8a1_e681, 0xe7d3_fbc8,
        0x21e1_cde6, 0xc337_07d6, 0xf4d5_0d87, 0x455a_14ed,
        0xa9e3_e905, 0xfcef_a3f8, 0x676f_02d9, 0x8d2a_4c8a,
        0xfffa_3942, 0x8771_f681, 0x6d9d_6122, 0xfde5_380c,
        0xa4be_ea44, 0x4bde_cfa9, 0xf6bb_4b60, 0xbebf_bc70,
        0x289b_7ec6, 0xeaa1_27fa, 0xd4ef_3085, 0x0488_1d05,
        0xd9d4_d039, 0xe6db_99e5, 0x1fa2_7cf8, 0xc4ac_5665,
        0xf429_2244, 0x432a_ff97, 0xab94_23a7, 0xfc93_a039,
        0x655b_59c3, 0x8f0c_cc92, 0xffef_f47d, 0x8584_5dd1,
        0x6fa8_7e4f, 0xfe2c_e6e0, 0xa301_4314, 0x4e08_11a1,
        0xf753_7e82, 0xbd3a_f235, 0x2ad7_d2bb, 0xeb86_d391
    ]

    public static func md5(_ message: [UInt8]) -> [UInt8] {
        var a0: UInt32 = 0x6745_2301
        var b0: UInt32 = 0xefcd_ab89
        var c0: UInt32 = 0x98ba_dcfe
        var d0: UInt32 = 0x1032_5476

        var bytes = message
        let bitLength = UInt64(message.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: bitLength >> (8 &* UInt64(i)))) }

        var offset = 0
        while offset < bytes.count {
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let base = offset + i * 4
                m[i] = UInt32(bytes[base])
                    | (UInt32(bytes[base + 1]) << 8)
                    | (UInt32(bytes[base + 2]) << 16)
                    | (UInt32(bytes[base + 3]) << 24)
            }

            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32
                var g: Int
                switch i {
                case 0..<16:
                    f = (b & c) | (~b & d)
                    g = i
                case 16..<32:
                    f = (b & d) | (c & ~d)
                    g = (5 * i + 1) % 16
                case 32..<48:
                    f = b ^ c ^ d
                    g = (3 * i + 5) % 16
                default:
                    f = c ^ (b | ~d)
                    g = (7 * i) % 16
                }
                f = f &+ a &+ md5K[i] &+ m[g]
                a = d
                d = c
                c = b
                b = b &+ rotl(f, md5Shift[i])
            }

            a0 = a0 &+ a
            b0 = b0 &+ b
            c0 = c0 &+ c
            d0 = d0 &+ d
            offset += 64
        }

        var out = [UInt8]()
        out.reserveCapacity(16)
        for word in [a0, b0, c0, d0] {
            out.append(UInt8(truncatingIfNeeded: word))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
            out.append(UInt8(truncatingIfNeeded: word >> 16))
            out.append(UInt8(truncatingIfNeeded: word >> 24))
        }
        return out
    }

    // MARK: SHA-1

    public static func sha1(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6745_2301, 0xefcd_ab89, 0x98ba_dcfe, 0x1032_5476, 0xc3d2_e1f0]

        var bytes = message
        let bitLength = UInt64(message.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for i in (0..<8).reversed() { bytes.append(UInt8(truncatingIfNeeded: bitLength >> (8 &* UInt64(i)))) }

        var offset = 0
        while offset < bytes.count {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let base = offset + i * 4
                w[i] = (UInt32(bytes[base]) << 24)
                    | (UInt32(bytes[base + 1]) << 16)
                    | (UInt32(bytes[base + 2]) << 8)
                    | UInt32(bytes[base + 3])
            }
            for i in 16..<80 {
                w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
            }

            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for i in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0..<20:
                    f = (b & c) | (~b & d)
                    k = 0x5a82_7999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ed9_eba1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8f1b_bcdc
                default:
                    f = b ^ c ^ d
                    k = 0xca62_c1d6
                }
                let temp = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = rotl(b, 30)
                b = a
                a = temp
            }

            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            offset += 64
        }

        var out = [UInt8]()
        out.reserveCapacity(20)
        for word in h {
            out.append(UInt8(truncatingIfNeeded: word >> 24))
            out.append(UInt8(truncatingIfNeeded: word >> 16))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
            out.append(UInt8(truncatingIfNeeded: word))
        }
        return out
    }

    // MARK: HMAC

    public static func hmacMD5(key: [UInt8], message: [UInt8]) -> [UInt8] {
        let blockSize = 64
        var normalizedKey = key.count > blockSize ? md5(key) : key
        if normalizedKey.count < blockSize {
            normalizedKey.append(contentsOf: [UInt8](repeating: 0, count: blockSize - normalizedKey.count))
        }
        var inner = [UInt8](repeating: 0, count: blockSize)
        var outer = [UInt8](repeating: 0, count: blockSize)
        for i in 0..<blockSize {
            inner[i] = normalizedKey[i] ^ 0x36
            outer[i] = normalizedKey[i] ^ 0x5c
        }
        return md5(outer + md5(inner + message))
    }

    // MARK: 工具

    public static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func md5Hex(_ string: String) -> String { hex(md5(Array(string.utf8))) }
    public static func sha1Hex(_ string: String) -> String { hex(sha1(Array(string.utf8))) }
    public static func hmacMD5Hex(key: String, message: String) -> String {
        hex(hmacMD5(key: Array(key.utf8), message: Array(message.utf8)))
    }

    private static func rotl(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        let shift = amount % 32
        guard shift != 0 else { return value }
        return (value << shift) | (value >> (32 - shift))
    }
}

// MARK: - SRun（深澜）载荷加密

/// xEncode 的混合步骤有两种互不等价的写法：
///  * `reference`：分步累加，与参考实现 AutoSZUWeb / 深澜前端 JS 一致（默认）；
///  * `standard`：Wheeler/Needham 官方 XXTEA 宏 `(A+B) ^ ((sum^y)+D)`。
/// 不同 SRun 部署可能使用不同变体，因此做成配置项；两者都有已知答案测试。
public enum XXTEAVariant: String, Codable, Sendable, CaseIterable {
    case reference
    case standard
}

public enum SRunCrypto {
    /// SRun 自定义 Base64 字母表（深澜默认实现）。
    public static let defaultAlphabet = "LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA"
    public static let standardAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    /// XXTEA（含长度字）加密，输出小端字节。
    public static func xEncode(_ content: String, key: String, variant: XXTEAVariant = .reference) -> [UInt8] {
        guard !content.isEmpty else { return [] }
        var v = words(Array(content.utf8), includeLength: true)
        var k = words(Array(key.utf8), includeLength: false)
        while k.count < 4 { k.append(0) }

        let n = v.count - 1
        guard n >= 1 else { return [] }
        var z = v[n]
        var y = v[0]
        let delta: UInt32 = 0x9e37_79b9
        var sum: UInt32 = 0
        var rounds = 6 + 52 / (n + 1)

        while rounds > 0 {
            sum = sum &+ delta
            let e = (sum >> 2) & 3
            var p = 0
            while p < n {
                y = v[p + 1]
                let mix = mixWord(z: z, y: y, sum: sum, k: k[Int((UInt32(p) & 3) ^ e)], variant: variant)
                v[p] = v[p] &+ mix
                z = v[p]
                p += 1
            }
            y = v[0]
            let mix = mixWord(z: z, y: y, sum: sum, k: k[Int((UInt32(n) & 3) ^ e)], variant: variant)
            v[n] = v[n] &+ mix
            z = v[n]
            rounds -= 1
        }

        var out = [UInt8]()
        out.reserveCapacity(v.count * 4)
        for word in v {
            out.append(UInt8(truncatingIfNeeded: word))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
            out.append(UInt8(truncatingIfNeeded: word >> 16))
            out.append(UInt8(truncatingIfNeeded: word >> 24))
        }
        return out
    }

    private static func mixWord(z: UInt32, y: UInt32, sum: UInt32, k: UInt32, variant: XXTEAVariant) -> UInt32 {
        switch variant {
        case .reference:
            var mx = (z >> 5) ^ (y << 2)
            mx = mx &+ (((y >> 3) ^ (z << 4)) ^ (sum ^ y))
            mx = mx &+ (k ^ z)
            return mx
        case .standard:
            let a = (z >> 5) ^ (y << 2)
            let b = (y >> 3) ^ (z << 4)
            return (a &+ b) ^ ((sum ^ y) &+ (k ^ z))
        }
    }

    /// 标准 Base64 后按 SRun 字母表重映射。
    public static func srunBase64(_ data: [UInt8], alphabet: String = defaultAlphabet) -> String {
        guard !data.isEmpty else { return "" }
        let standard = Data(data).base64EncodedString()
        let standardChars = Array(standardAlphabet.utf8)
        let customChars = Array(alphabet.utf8)
        var out = [UInt8]()
        out.reserveCapacity(standard.utf8.count)
        for byte in standard.utf8 {
            if let index = standardChars.firstIndex(of: byte) {
                out.append(customChars[index])
            } else {
                out.append(byte) // '=' 等填充字符保持不变
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `{SRBX1}` + XXTEA + 自定义 Base64，得到 `info` 参数。
    public static func encodeInfo(
        json: String,
        challenge: String,
        alphabet: String = defaultAlphabet,
        variant: XXTEAVariant = .reference
    ) -> String {
        "{SRBX1}" + srunBase64(xEncode(json, key: challenge, variant: variant), alphabet: alphabet)
    }

    /// challenge 逐段前置的 SHA1 校验串，与参考实现一致。
    public static func checksum(
        challenge: String,
        username: String,
        passwordMD5: String,
        acID: String,
        clientIP: String,
        info: String,
        callbackN: String = "200",
        type: String = "1"
    ) -> String {
        var source = ""
        source += challenge + username
        source += challenge + passwordMD5
        source += challenge + acID
        source += challenge + clientIP
        source += challenge + callbackN
        source += challenge + type
        source += challenge + info
        return Digest.sha1Hex(source)
    }

    /// 密码字段：HMAC-MD5(key: challenge, msg: password) 的十六进制。
    public static func passwordDigest(password: String, challenge: String) -> String {
        Digest.hmacMD5Hex(key: challenge, message: password)
    }

    /// 按参考实现的键顺序手工构造 info JSON（避免依赖字典顺序）。
    public static func infoJSON(username: String, password: String, ip: String, acid: String) -> String {
        let fields: [(String, String)] = [
            ("username", username),
            ("password", password),
            ("ip", ip),
            ("acid", acid),
            ("enc_ver", "srun_bx1")
        ]
        let body = fields.map { "\"\($0.0)\":\(jsonString($0.1))" }.joined(separator: ",")
        return "{" + body + "}"
    }

    public static func jsonString(_ value: String) -> String {
        var out = "\""
        for character in value.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out + "\""
    }

    private static func words(_ bytes: [UInt8], includeLength: Bool) -> [UInt32] {
        var count = (bytes.count + 3) / 4
        var result = [UInt32](repeating: 0, count: includeLength ? count + 1 : count)
        if includeLength {
            result[count] = UInt32(bytes.count)
            count -= 1
        }
        var index = 0
        while index < bytes.count {
            let wordIndex = index / 4
            let offset = UInt32((index % 4) * 8)
            result[wordIndex] |= UInt32(bytes[index]) << offset
            index += 1
        }
        return result
    }
}
