#!/usr/bin/env python3
"""SRun（深澜）xEncode 参考实现 & 测试向量生成器。

用途：
 1. 与 Swift 端 `SRunCrypto` 交叉核对（同一算法用两种写法实现并对比）；
 2. 生成 Tests 里的已知答案（KAT）。

算法来源：参考项目 AutoSZUWeb `src/srun.cpp`（MIT）中的 XEncode 实现。
该实现的混合步骤是分步累加：
    mx  = (z>>5 ^ y<<2)
    mx += (y>>3 ^ z<<4) ^ (sum ^ y)
    mx += k[(p&3)^e] ^ z
注意这与 Wheeler/Needham 官方 XXTEA 宏 `((A+B) ^ ((sum^y)+D))` 写法不同，
两种写法结果并不等价（见下方 `variants` 对比），因此 Swift 端保留两种变体，
默认使用与参考实现一致的 `reference`。
"""
import base64
import hashlib
import hmac
import json

MASK = 0xFFFFFFFF
DELTA = 0x9E3779B9
SRUN_ALPHA = "LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA"
STD_ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


def words(data: bytes, include_length: bool):
    n = (len(data) + 3) // 4
    v = [0] * (n + 1 if include_length else n)
    for i, b in enumerate(data):
        v[i >> 2] |= b << ((i & 3) * 8)
    if include_length:
        v[n] = len(data)
    return v


def mix_reference(v, k):
    """分步累加写法（与参考实现 AutoSZUWeb / srun.cpp 一致）。"""
    n = len(v) - 1
    z, y = v[n], v[0]
    total = 0
    rounds = 6 + 52 // (n + 1)
    while rounds > 0:
        total = (total + DELTA) & MASK
        e = (total >> 2) & 3
        for p in range(n):
            y = v[p + 1]
            mx = ((z >> 5) ^ ((y << 2) & MASK)) & MASK
            mx = (mx + (((y >> 3) ^ ((z << 4) & MASK)) ^ (total ^ y))) & MASK
            mx = (mx + (k[(p & 3) ^ e] ^ z)) & MASK
            v[p] = (v[p] + mx) & MASK
            z = v[p]
        y = v[0]
        mx = ((z >> 5) ^ ((y << 2) & MASK)) & MASK
        mx = (mx + (((y >> 3) ^ ((z << 4) & MASK)) ^ (total ^ y))) & MASK
        mx = (mx + (k[(n & 3) ^ e] ^ z)) & MASK
        v[n] = (v[n] + mx) & MASK
        z = v[n]
        rounds -= 1
    return v


def mix_standard(v, k):
    """官方 XXTEA 宏写法：(A+B) ^ ((sum^y)+D)。"""
    n = len(v) - 1
    z, y = v[n], v[0]
    total = 0
    rounds = 6 + 52 // (n + 1)
    while rounds > 0:
        total = (total + DELTA) & MASK
        e = (total >> 2) & 3
        for p in range(n):
            y = v[p + 1]
            a = ((z >> 5) ^ ((y << 2) & MASK))
            b = ((y >> 3) ^ ((z << 4) & MASK))
            mx = ((a + b) ^ ((total ^ y) + (k[(p & 3) ^ e] ^ z))) & MASK
            v[p] = (v[p] + mx) & MASK
            z = v[p]
        y = v[0]
        a = ((z >> 5) ^ ((y << 2) & MASK))
        b = ((y >> 3) ^ ((z << 4) & MASK))
        mx = ((a + b) ^ ((total ^ y) + (k[(n & 3) ^ e] ^ z))) & MASK
        v[n] = (v[n] + mx) & MASK
        z = v[n]
        rounds -= 1
    return v


def words_to_bytes(v):
    out = bytearray()
    for word in v:
        out += word.to_bytes(4, "little")
    return bytes(out)


def xencode(content: str, key: str, variant: str = "reference") -> bytes:
    if not content:
        return b""
    v = words(content.encode("utf-8"), True)
    k = words(key.encode("utf-8"), False)
    while len(k) < 4:
        k.append(0)
    v = mix_reference(v, k) if variant == "reference" else mix_standard(v, k)
    return words_to_bytes(v)


def srun_base64(data: bytes, alphabet: str = SRUN_ALPHA) -> str:
    standard = base64.b64encode(data).decode("ascii")
    return "".join(alphabet[STD_ALPHA.index(ch)] if ch in STD_ALPHA else ch for ch in standard)


def info_json(username: str, password: str, ip: str, acid: str) -> str:
    return json.dumps(
        {"username": username, "password": password, "ip": ip, "acid": acid, "enc_ver": "srun_bx1"},
        separators=(",", ":"),
        ensure_ascii=False,
    )


def main():
    vectors = {}

    # 1) 摘要算法标准向量
    vectors["md5_abc"] = hashlib.md5(b"abc").hexdigest()
    vectors["sha1_abc"] = hashlib.sha1(b"abc").hexdigest()
    vectors["hmac_md5_rfc2202_case1"] = hmac.new(bytes([0x0B] * 16), b"Hi There", hashlib.md5).hexdigest()

    # 2) xEncode 两种变体
    key = "challenge-0123456789abcdef"
    payload = info_json("2024000000", "p@ss w0rd!", "10.20.30.40", "1")
    ref = xencode(payload, key, "reference")
    std = xencode(payload, key, "standard")
    vectors["xencode_reference_b64"] = srun_base64(ref)
    vectors["xencode_standard_b64"] = srun_base64(std)
    vectors["xencode_variants_differ"] = ref != std

    # 3) 密码摘要 + 完整 chksum
    challenge = "1a2b3c4d5e6f7g8h"
    password_md5 = hmac.new(challenge.encode(), "p@ss w0rd!".encode(), hashlib.md5).hexdigest()
    info = "{SRBX1}" + srun_base64(xencode(payload, challenge, "reference"))
    checksum_source = (
        challenge + "2024000000"
        + challenge + password_md5
        + challenge + "1"
        + challenge + "10.20.30.40"
        + challenge + "200"
        + challenge + "1"
        + challenge + info
    )
    vectors["password_md5"] = password_md5
    vectors["info"] = info
    vectors["chksum"] = hashlib.sha1(checksum_source.encode()).hexdigest()

    # 4) 另一种长度（非 4 字节对齐）覆盖 words() 补零路径
    vectors["xencode_unaligned_b64"] = srun_base64(xencode("abc", "k", "reference"))

    print(json.dumps({"payload": payload, "key": key, "challenge": challenge, "vectors": vectors}, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
