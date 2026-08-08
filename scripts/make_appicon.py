#!/usr/bin/env python3
"""
生成 kaca 的占位 App 图标（resources/AppIcon.icns）。

纯标准库实现（无第三方依赖）：
  - 用 zlib + crc32 手写 PNG 编码器，画一个「品牌蓝圆角方块 + 白色录制圆点」；
  - 4x 超采样做抗锯齿；
  - 通过 iconset 目录交给系统 iconutil 转成 .icns。

用法：
    python3 scripts/make_appicon.py
或经 Makefile 的 AppIcon.icns 目标间接调用。
"""
import binascii
import os
import struct
import subprocess
import zlib
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ICONSET = os.path.join(ROOT, "resources", "AppIcon.iconset")
ICNS = os.path.join(ROOT, "resources", "AppIcon.icns")

BG = (0x3B, 0x82, 0xF6)   # 品牌蓝 #3B82F6
DOT = (0xFF, 0xFF, 0xFF)  # 白色录制圆点

# (像素尺寸, iconset 文件名) —— 覆盖 iconutil 期望的全部规格
SIZES = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]


def inside_rounded(x, y, w, h, r):
    """判断点 (x,y)（可为浮点）是否落在圆角矩形内（圆角半径 r）。"""
    if x < 0 or x >= w or y < 0 or y >= h:
        return False
    in_x = (r <= x < w - r)
    in_y = (r <= y < h - r)
    if in_x or in_y:
        return True
    cx = r if x < r else w - r
    cy = r if y < r else h - r
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def render(size):
    """4x 超采样渲染 size x size 的 RGBA 像素，返回 bytearray。"""
    SS = 4
    big = size * SS
    r = big * 0.22
    rr = big * 0.16
    cx = big / 2.0
    cy = big / 2.0
    buf = bytearray(big * big * 4)
    for y in range(big):
        for x in range(big):
            idx = (y * big + x) * 4
            px, py = x + 0.5, y + 0.5
            if inside_rounded(px, py, big, big, r):
                R, G, B = BG
                A = 255
            else:
                R, G, B, A = 0, 0, 0, 0
            d = (px - cx) ** 2 + (py - cy) ** 2
            if d <= rr * rr:
                R, G, B = DOT
                A = 255
            buf[idx:idx + 4] = bytes((R, G, B, A))
    # 降采样：对 SS x SS 块取平均（含 alpha，得到抗锯齿边缘）
    out = bytearray(size * size * 4)
    for y in range(size):
        for x in range(size):
            sr = sg = sb = sa = 0
            for dy in range(SS):
                for dx in range(SS):
                    bx = x * SS + dx
                    by = y * SS + dy
                    bidx = (by * big + bx) * 4
                    sr += buf[bidx]
                    sg += buf[bidx + 1]
                    sb += buf[bidx + 2]
                    sa += buf[bidx + 3]
            n = SS * SS
            oidx = (y * size + x) * 4
            out[oidx:oidx + 4] = bytes(
                (sr // n, sg // n, sb // n, sa // n)
            )
    return out


def png_encode(size, rgba):
    """手写 PNG（8-bit RGBA）编码器。"""
    raw = bytearray()
    stride = size * 4
    for y in range(size):
        raw.append(0)  # filter: None
        raw.extend(rgba[y * stride:(y + 1) * stride])
    comp = zlib.compress(bytes(raw), 9)

    def chunk(typ, data):
        body = struct.pack(">I", len(data)) + typ + data
        crc = binascii.crc32(typ + data) & 0xFFFFFFFF
        return body + struct.pack(">I", crc)

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", comp) + chunk(b"IEND", b"")


def main():
    os.makedirs(ICONSET, exist_ok=True)
    for size, name in SIZES:
        png = png_encode(size, render(size))
        with open(os.path.join(ICONSET, name), "wb") as f:
            f.write(png)
        print("  wrote %s (%dx%d)" % (name, size, size))
    # 交给系统 iconutil 转 icns
    subprocess.run(
        ["iconutil", "--convert", "icns", "--output", ICNS, ICONSET],
        check=True,
    )
    print("generated %s" % ICNS)


if __name__ == "__main__":
    try:
        main()
    except FileNotFoundError as e:
        sys.stderr.write(
            "错误：缺少 iconutil（仅 macOS 提供）。请在本机运行。\n%s\n" % e
        )
        sys.exit(1)
