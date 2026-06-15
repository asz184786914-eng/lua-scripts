#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
通用激活码生成器
支持: Unity加速器 / ACBypass

用法:
  python3 keygen.py <设备码>           # Unity加速器模式
  python3 keygen.py -a <设备码>        # ACBypass模式
  python3 keygen.py --acbypass <设备码> # ACBypass模式
"""

import sys
import struct

MASTER_KEY = "xy435116694754"
ACTIVATION_SECRET_SPEED = "SpeedHack2025XY"
ACTIVATION_SECRET_AC = "ACBypass2026XY"
B32 = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

def xor_encode(data, key):
    key_b = key.encode('latin-1') if isinstance(key, str) else key
    r = bytearray()
    for i, b in enumerate(data):
        r.append(b ^ key_b[i % len(key_b)])
    return bytes(r)

def b32_encode(data):
    bits = 0; val = 0; result = []
    for b in data:
        val = (val << 8) | b; bits += 8
        while bits >= 5:
            bits -= 5; idx = (val >> bits) & 0x1F
            result.append(B32[idx])
            val = val & ((1 << bits) - 1)
    if bits > 0:
        idx = (val & ((1 << bits) - 1)) << (5 - bits)
        result.append(B32[idx])
    return ''.join(result)

def b32_decode(s):
    result = bytearray(); val = 0; bits = 0
    for c in s.upper():
        idx = B32.find(c)
        if idx < 0: continue
        val = (val << 5) | idx; bits += 5
        while bits >= 8:
            bits -= 8; result.append((val >> bits) & 0xFF)
            val = val & ((1 << bits) - 1)
    return bytes(result)

def format_code(s, group=4, sep="-"):
    return sep.join([s[i:i+group] for i in range(0, len(s), group)])

def fnv1a_32(s, seed=0x811c9dc5):
    h = seed
    for c in s.encode('utf-8'):
        h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF
    return h

def fp_hash_bytes(fp_str):
    h1 = fnv1a_32(fp_str, 0x811c9dc5)
    h2 = fnv1a_32(fp_str, 0x1234abcd)
    return struct.pack('<I', h1) + struct.pack('<I', h2)[:1]

def act_hash_bytes(fp_hex, secret):
    act_input = fp_hex + secret
    ah1 = fnv1a_32(act_input, 0x5678ef01)
    ah2 = fnv1a_32(act_input, 0x9abcdef0)
    ah3 = fnv1a_32(act_input, 0x13579bdf)
    return struct.pack('<I', ah1) + struct.pack('<I', ah2) + struct.pack('<I', ah3)[:2]

def decrypt_device_code(device_code):
    dc = device_code.upper().replace("-", "").replace(" ", "")
    if len(dc) != 8:
        return None
    encrypted = b32_decode(dc)
    if len(encrypted) < 5:
        return None
    fp_hash = xor_encode(encrypted[:5], MASTER_KEY[:5])
    return fp_hash.hex()

def generate_activation_key(device_code, secret):
    fp_hex = decrypt_device_code(device_code)
    if not fp_hex:
        return None
    act_hash = act_hash_bytes(fp_hex, secret)
    encrypted = xor_encode(act_hash, MASTER_KEY[:10])
    code = b32_encode(encrypted)
    return format_code(code[:16])

def main():
    acbypass_mode = False
    device_code = None

    args = sys.argv[1:]
    for arg in args:
        if arg in ("-a", "--acbypass"):
            acbypass_mode = True
        else:
            device_code = arg.strip()

    secret = ACTIVATION_SECRET_AC if acbypass_mode else ACTIVATION_SECRET_SPEED
    tool_name = "ACBypass" if acbypass_mode else "Unity加速器"

    if not device_code:
        print("╔══════════════════════════════════════╗")
        print("║  通用激活码生成器 v2.0              ║")
        print("║  署名: xy435116694754               ║")
        print("╚══════════════════════════════════════╝")
        print()
        print("用法:")
        print("  python3 keygen.py <设备码>           # Unity加速器")
        print("  python3 keygen.py -a <设备码>        # ACBypass")
        print()
        print("设备码格式: XXXX-XXXX (8位字母数字)")
        print("激活码格式: XXXX-XXXX-XXXX-XXXX (16位字母数字)")
        sys.exit(0)

    print("╔══════════════════════════════════════╗")
    print(f"║  {tool_name} 激活码生成器" + " " * max(0, 22 - len(tool_name.encode('utf-8')) + len(tool_name)) + "║")
    print("╚══════════════════════════════════════╝")
    print()
    print(f"  工具: {tool_name}")
    print(f"  设备码: {device_code}")

    fp_hex = decrypt_device_code(device_code)
    if not fp_hex:
        print()
        print("  ❌ 设备码无效！请检查格式 (XXXX-XXXX)")
        sys.exit(1)

    print(f"  指纹哈希: {fp_hex}")

    activation_key = generate_activation_key(device_code, secret)
    if not activation_key:
        print()
        print("  ❌ 生成失败！")
        sys.exit(1)

    print()
    print(f"  ✅ 激活码: {activation_key}")
    print()
    print("  将此激活码发送给用户即可")

if __name__ == "__main__":
    main()
