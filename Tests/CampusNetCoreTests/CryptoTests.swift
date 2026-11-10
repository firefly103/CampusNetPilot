import XCTest
@testable import CampusNetCore

/// 已知答案测试（KAT）。期望值由 tools/srun_reference.py 生成，
/// 该脚本同时用两种写法实现 XXTEA 混合并对标准摘要算法做了交叉核对。
final class CryptoTests: XCTestCase {
    func testMD5KnownVectors() {
        XCTAssertEqual(Digest.md5Hex("abc"), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(Digest.md5Hex(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(
            Digest.md5Hex("The quick brown fox jumps over the lazy dog"),
            "9e107d9d372bb6826bd81d3542a419d6"
        )
        // 长输入覆盖多分组路径
        XCTAssertEqual(Digest.md5Hex(String(repeating: "a", count: 1000)).count, 32)
    }

    func testSHA1KnownVectors() {
        XCTAssertEqual(Digest.sha1Hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(Digest.sha1Hex(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }

    func testHMACMD5RFC2202Case1() {
        let key = [UInt8](repeating: 0x0b, count: 16)
        let digest = Digest.hmacMD5(key: key, message: Array("Hi There".utf8))
        XCTAssertEqual(Digest.hex(digest), "9294727a3638bb1c13f48ef8158bfc9d")
    }

    private let payload = #"{"username":"2024000000","password":"p@ss w0rd!","ip":"10.20.30.40","acid":"1","enc_ver":"srun_bx1"}"#
    private let challenge = "1a2b3c4d5e6f7g8h"

    func testInfoJSONMatchesReferenceOrdering() {
        let json = SRunCrypto.infoJSON(
            username: "2024000000",
            password: "p@ss w0rd!",
            ip: "10.20.30.40",
            acid: "1"
        )
        XCTAssertEqual(json, payload)
    }

    func testXEncodeReferenceVariant() {
        let encoded = SRunCrypto.xEncode(payload, key: "challenge-0123456789abcdef", variant: .reference)
        XCTAssertEqual(
            SRunCrypto.srunBase64(encoded),
            "KV7pGTNsPc/zivyi7L0KH4HB3JS95xG9KpIP8HQTijNQXpcycCmSX0rrYenWUpXEUpNX3lkkUzUcIBTGTEBZ31yUeS8YcZuOQQTVe/HLRjX05J/g8OKrLS9kGmEw9C0wfpBYeG88JmS="
        )
    }

    func testXEncodeStandardVariant() {
        let encoded = SRunCrypto.xEncode(payload, key: "challenge-0123456789abcdef", variant: .standard)
        XCTAssertEqual(
            SRunCrypto.srunBase64(encoded),
            "SjNUtv4OR0TmTZ8Zte/Byn51hxlwm9EwBAB5BA/izGWGivaSv8Pv88zWLdxJdyIp+Sg0hVpXDUd44619HLlv+saNIScaCo9Y73ewV8XnDNlapkYPlNQGly8fli/L1QijCZKCgrNCacP="
        )
    }

    func testXEncodeVariantsDiffer() {
        let reference = SRunCrypto.xEncode(payload, key: challenge, variant: .reference)
        let standard = SRunCrypto.xEncode(payload, key: challenge, variant: .standard)
        XCTAssertNotEqual(SRunCrypto.srunBase64(reference), SRunCrypto.srunBase64(standard))
    }

    func testXEncodeUnalignedLength() {
        let encoded = SRunCrypto.xEncode("abc", key: "k")
        XCTAssertEqual(SRunCrypto.srunBase64(encoded), "LbZFhpeuEIZ=")
    }

    func testPasswordDigest() {
        XCTAssertEqual(
            SRunCrypto.passwordDigest(password: "p@ss w0rd!", challenge: challenge),
            "fdf0c9ab36723872050dad775b95e95f"
        )
    }

    func testInfoPayload() {
        let info = SRunCrypto.encodeInfo(json: payload, challenge: challenge)
        XCTAssertEqual(
            info,
            "{SRBX1}QzGGMtqGcBHTszl+MP1r8dISLo0sslDgDW89pIDiBTjd3Muml9x67gKW6swuJmis/XVUGn3aiPt/cfNboKhBqonAVhoImpatS5OO+0Xz644VZjjFQTJENHGcy4f/ONNv6tktH2bpoMD="
        )
    }

    func testChecksum() {
        let passwordMD5 = SRunCrypto.passwordDigest(password: "p@ss w0rd!", challenge: challenge)
        let info = SRunCrypto.encodeInfo(json: payload, challenge: challenge)
        let checksum = SRunCrypto.checksum(
            challenge: challenge,
            username: "2024000000",
            passwordMD5: passwordMD5,
            acID: "1",
            clientIP: "10.20.30.40",
            info: info
        )
        XCTAssertEqual(checksum, "bd90cec3c51e1b404b197477749c7fe6c3ab2456")
    }

    func testJSONEscaping() {
        XCTAssertEqual(SRunCrypto.jsonString("a\"b\\c"), "\"a\\\"b\\\\c\"")
        XCTAssertEqual(SRunCrypto.jsonString("中文 SSID"), "\"中文 SSID\"")
    }

    func testJSONPUnwrap() {
        XCTAssertEqual(TextTools.unwrapJSONP("_({ \"a\": 1 })"), "{ \"a\": 1 }")
        XCTAssertNil(TextTools.unwrapJSONP("plain json"))
        XCTAssertEqual(TextTools.firstInteger(after: "ac_id=", in: "?ac_id=88&x=1"), "88")
        XCTAssertNil(TextTools.firstInteger(after: "ac_id=", in: "?ac_id=abc"))
    }
}
