"""设备后端兼容层：让同一份训练代码跑在 NVIDIA GPU（cuda）与华为 Ascend NPU（npu）上。

为什么需要单独一个文件：
    原代码到处是 `torch.cuda.*` 与 `device="cuda"`，直接改成 `torch.npu.*` 会让
    手头的 GPU 机器无法再跑；改成大量 `if hasattr` 内联判断又会把同一段逻辑复制
    到 train_v3 / train_mono / train_v2 / vram_cache 四处。集中到这里，各调用点只是
    「先拿到 device_type，再交给本模块分发」，CUDA 旧行为一行不变。

torch_npu 的用法与 torch.cuda 对称：
    import torch_npu 之后，torch.npu 才会注册进 torch 命名空间，
    此后 torch.npu.is_available() / empty_cache() / memory_allocated() /
    memory_reserved() / get_device_properties() 与 torch.cuda 同名同参。
"""
from __future__ import annotations

import torch

#: 需要特殊分发的加速器类型；cpu/mps 不在此列，走各自原有逻辑。
_ACCEL_TYPES = ("cuda", "npu")


def is_npu_available() -> bool:
    """Ascend NPU 是否可用。

    为什么用 try import 而不是直接 hasattr(torch, "npu")：
        torch.npu 只有在 import torch_npu 成功后才存在。GPU/CPU 镜像里通常
        没有装 torch_npu，此时 import 失败即返回 False，绝不抛给上层。
    """
    try:
        import torch_npu  # noqa: F401  # 仅导入以注册 torch.npu，不使用其符号
    except ImportError:
        return False
    return bool(torch.npu.is_available())


def get_accelerator(device_type: str):
    """按 device_type 取到真正提供显存接口的模块（torch.cuda / torch.npu）。

    拿不到（cpu/mps，或 npu 未注册）时返回 None，调用方据此跳过加速器专属逻辑。
    """
    if device_type not in _ACCEL_TYPES:
        return None
    return getattr(torch, device_type, None)


def device_available(device_type: str) -> bool:
    """该类型的设备此刻是否真的可用（供"开显存缓存前先确认"之类的守卫使用）。"""
    if device_type == "npu":
        return is_npu_available()
    if device_type == "cuda":
        return torch.cuda.is_available()
    return False


def empty_cache(device_type: str) -> None:
    """清空对应后端的显存缓存；后端没有该能力时静默跳过。

    本训练代码库当前没有 torch.cuda.empty_cache 的调用点（唯一的 empty_cache
    是 train_mono/train_v2 里的 torch.mps.empty_cache，MPS 专用），故此处暂
    无调用方；保留为对称 API，供后续显存碎片整理时按 device_type 调用。
    """
    accel = get_accelerator(device_type)
    if accel is not None and hasattr(accel, "empty_cache"):
        accel.empty_cache()


def synchronize(device_type: str, device=None) -> None:
    """同步对应后端；没有该能力时静默跳过。

    本训练代码库当前没有 torch.cuda.synchronize 的调用点，暂为对称 API 保留，
    供需要计时或调试对齐时按 device_type 调用。
    """
    accel = get_accelerator(device_type)
    if accel is not None and hasattr(accel, "synchronize"):
        accel.synchronize(device) if device is not None else accel.synchronize()


def memory_allocated(device_type: str, device=None) -> int:
    """已分配显存字节数；后端不支持时返回 0（仅用于日志，返回 0 不会中断训练）。"""
    accel = get_accelerator(device_type)
    if accel is not None and hasattr(accel, "memory_allocated"):
        return accel.memory_allocated(device)
    return 0


def memory_reserved(device_type: str, device=None) -> int:
    """已保留（含缓存块）显存字节数；后端不支持时返回 0（仅用于日志）。"""
    accel = get_accelerator(device_type)
    if accel is not None and hasattr(accel, "memory_reserved"):
        return accel.memory_reserved(device)
    return 0


def get_device_properties(device_type: str, device):
    """取设备属性（含 total_memory）；后端不支持时抛错——容量断言必须在能判断时才做。"""
    accel = get_accelerator(device_type)
    if accel is None:
        raise RuntimeError(f"device_type={device_type} 没有 get_device_properties")
    return accel.get_device_properties(device)
