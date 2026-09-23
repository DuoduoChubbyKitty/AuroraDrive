#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""CoreGraphics 屏幕抓取（ctypes 实现，无需 pyobjc）

用法:
    cgrab.py <输出png>                  # 抓主屏全屏（物理像素 2940x1912）
    cgrab.py <输出png> <x> <y> <w> <h>  # 抓指定矩形（逻辑坐标，内部按 2x 换算）
"""

import ctypes
import ctypes.util
import sys

import numpy as np
import cv2

cg = ctypes.CDLL(ctypes.util.find_library('CoreGraphics'))
cf = ctypes.CDLL(ctypes.util.find_library('CoreFoundation'))


class CGPoint(ctypes.Structure):
    _fields_ = [('x', ctypes.c_double), ('y', ctypes.c_double)]


class CGSize(ctypes.Structure):
    _fields_ = [('width', ctypes.c_double), ('height', ctypes.c_double)]


class CGRect(ctypes.Structure):
    _fields_ = [('origin', CGPoint), ('size', CGSize)]


cg.CGMainDisplayID.restype = ctypes.c_uint32
cg.CGDisplayCreateImage.restype = ctypes.c_void_p
cg.CGDisplayCreateImage.argtypes = [ctypes.c_uint32]
cg.CGDisplayCreateImageForRect.restype = ctypes.c_void_p
cg.CGDisplayCreateImageForRect.argtypes = [ctypes.c_uint32, CGRect]
for _fn in ('CGImageGetWidth', 'CGImageGetHeight', 'CGImageGetBytesPerRow',
            'CGImageGetBitsPerPixel'):
    getattr(cg, _fn).restype = ctypes.c_size_t
    getattr(cg, _fn).argtypes = [ctypes.c_void_p]
cg.CGImageGetDataProvider.restype = ctypes.c_void_p
cg.CGImageGetDataProvider.argtypes = [ctypes.c_void_p]
cg.CGDataProviderCopyData.restype = ctypes.c_void_p
cg.CGDataProviderCopyData.argtypes = [ctypes.c_void_p]
cf.CFDataGetLength.restype = ctypes.c_long
cf.CFDataGetLength.argtypes = [ctypes.c_void_p]
cf.CFDataGetBytePtr.restype = ctypes.c_void_p
cf.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]
cf.CFRelease.argtypes = [ctypes.c_void_p]


def _to_bgr(img):
    w = cg.CGImageGetWidth(img)
    h = cg.CGImageGetHeight(img)
    bpr = cg.CGImageGetBytesPerRow(img)
    bpp = cg.CGImageGetBitsPerPixel(img)
    prov = cg.CGImageGetDataProvider(img)
    data = cg.CGDataProviderCopyData(prov)
    ln = cf.CFDataGetLength(data)
    ptr = cf.CFDataGetBytePtr(data)
    buf = ctypes.string_at(ptr, ln)

    need = h * bpr
    if len(buf) < need:
        buf = buf + b'\x00' * (need - len(buf))
    arr = np.frombuffer(buf[:need], dtype=np.uint8).reshape((h, bpr))
    arr = arr[:, :w * (bpp // 8)].reshape((h, w, bpp // 8))
    if bpp == 32:
        out = cv2.cvtColor(arr, cv2.COLOR_BGRA2BGR)
    elif bpp == 24:
        out = arr[:, :, :3].copy()
    else:
        raise SystemExit(f'不支持的 bitsPerPixel={bpp}')
    # 进程即用即退，不手动 CFRelease（prov/data 由 img 持有，误释放会 segfault）
    return out


def grab(rect=None):
    did = cg.CGMainDisplayID()
    if rect:
        x, y, w, h = [float(v) for v in rect]
        r = CGRect(CGPoint(x, y), CGSize(w, h))
        img = cg.CGDisplayCreateImageForRect(did, r)
        if not img:
            raise SystemExit('CGDisplayCreateImageForRect 返回空')
        return _to_bgr(img)
    img = cg.CGDisplayCreateImage(did)
    if not img:
        raise SystemExit('CGDisplayCreateImage 返回空 —— 多半缺「屏幕录制」权限')
    return _to_bgr(img)


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    out = sys.argv[1]
    rect = [int(v) for v in sys.argv[2:6]] if len(sys.argv) >= 6 else None
    im = grab(rect)
    cv2.imwrite(out, im)
    print(f'{out}  {im.shape[1]}x{im.shape[0]}')
