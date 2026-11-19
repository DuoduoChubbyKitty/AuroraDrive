"""把全部帧一次性预解码进显存，训练时按索引直取，彻底消除重复解码。

为什么需要（问题的量化）：
    V3 的输入是 24 帧滑动窗口 [t, t-23]，相邻样本的窗口重叠 23 帧。
    当前实现每个样本都独立重新解码这 24 张 JPEG：
        · 连续采样时，一个 batch=32 只涉及 55 张不同的图，却解码了 768 次（14x 冗余）
        · 训练用 shuffle=True，乱序后 batch 内零重叠，缓存命中率为 0
    结果就是 GPU 每 batch 只忙约 30ms，CPU 却要花 3.7s 解码，GPU 空转 99%。

本模块的做法：
    启动时把所有会被索引到的帧解码一次，以 uint8 常驻显存：
        hi: [N,3,224,384] ≈ 258 KB/帧
        lo: [N,3,112,192] ≈  65 KB/帧
    合计 68,106 帧约 20.5 GiB，A100 80G 显存装得下（模型+激活约 15G，共约 36G）。
    训练时每个样本只是从显存里 gather 24 个切片，耗时从毫秒级降到微秒级。

为什么 lo 也要单独存，而不是训练时从 hi 缩放：
    现有实现用 PIL 的 BILINEAR 缩放到 112×192。若改用 torch 的 interpolate，
    核函数与 PIL 不完全相同，像素值会有细微差异 —— 等于悄悄换了训练数据。
    多存 4 GiB 换"与原实现逐像素一致"，值得。

正确性保证：
    提供 verify_against_direct()：临时关掉缓存、走原始解码路径，再与缓存路径
    逐元素比对。训练脚本会在正式开跑前自动调用，不一致立即中止。
    这保证"加速"不会偷偷改变训练数据。
"""
from __future__ import annotations

import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Dict, List, Sequence, Set, Tuple

import numpy as np
import torch

from npu_compat import get_device_properties, memory_allocated, memory_reserved

try:  # PIL 缺失时由 dataset_v3 给出更明确的报错，这里只做兜底
    from PIL import Image
except ImportError:  # pragma: no cover
    Image = None


class V3VRAMFrameCache:
    """把 dataset 会索引到的所有帧预解码进 device（通常是 cuda / npu）。

    只缓存"确实会被读到"的帧：从 dataset.index 反推窗口覆盖的帧号，
    避免为缺失帧或无引用的帧浪费显存。
    """

    def __init__(
        self,
        dataset,
        device: torch.device | str,
        decode_threads: int = 8,
        use_gpu_decode: str = "auto",
        log=print,
    ):
        if Image is None:
            raise RuntimeError("需要 Pillow：pip install pillow")

        self.device = torch.device(device)
        self.image_size: Tuple[int, int] = dataset.image_size      # (h, w)
        self.lowres_size: Tuple[int, int] = dataset.lowres_size    # (h, w)
        self.history: int = dataset.history
        self.decode_threads = max(1, int(decode_threads))
        self.log = log

        self._hi: Dict[Path, torch.Tensor] = {}
        self._lo: Dict[Path, torch.Tensor] = {}

        t_start = time.perf_counter()
        needed = self._collect_needed_frames(dataset)
        total_refs = sum(len(v) for v in needed.values())
        self.log(
            f"[VRAMCache] 待预解码: {len(needed)} 个 clip，{total_refs} 帧，"
            f"设备={self.device}"
        )
        # 分配前先确认装得下：中途 OOM 会白烧几分钟算力，且错误信息说不清缺多少。
        need_bytes = self._check_vram_capacity(needed)
        self.log(f"[VRAMCache] 预计占用 {need_bytes/1024**3:.2f} GiB")

        # GPU 解码是否可用，先做一次小样本验证；不可用或不一致则回落到 PIL
        self.decode_mode = "pil"
        if str(use_gpu_decode).lower() in ("1", "true", "auto", "yes"):
            ok, reason = self._probe_gpu_decode(needed)
            if ok:
                self.decode_mode = "nvjpeg"
                self.log("[VRAMCache] GPU 解码（nvJPEG）可用，预解码走 GPU")
            else:
                self.log(f"[VRAMCache] GPU 解码不可用（{reason}），回落到 CPU 多线程 PIL")

        for i, (clip, frames) in enumerate(needed.items(), 1):
            self._preload_clip(clip, frames)
            if i % 5 == 0 or i == len(needed):
                used = 0
                if self.device.type in ("cuda", "npu"):
                    used = memory_allocated(self.device.type, self.device) / 1024**3
                    reserved = memory_reserved(self.device.type, self.device) / 1024**3
                    self.log(
                        f"[VRAMCache] {i}/{len(needed)} clip 完成  "
                        f"显存已用 {used:.1f} GiB（保留 {reserved:.1f} GiB）"
                    )
                else:
                    self.log(f"[VRAMCache] {i}/{len(needed)} clip 完成")

        total = sum(t.numel() * t.element_size() for t in self._hi.values())
        total += sum(t.numel() * t.element_size() for t in self._lo.values())
        self.total_bytes = total
        self.log(
            f"[VRAMCache] 预解码完成，用时 {time.perf_counter()-t_start:.1f}s，"
            f"占用 {total/1024**3:.2f} GiB（解码方式={self.decode_mode}）"
        )

    # -- 构建 ---------------------------------------------------------------

    def _collect_needed_frames(self, dataset) -> Dict[Path, Set[int]]:
        """从索引反推每个 clip 需要哪些帧号（含窗口回溯与 clamp）。

        ⚠️ NUM_HI_FRAMES 必须从 dataset_v3 取，不能写死 3：
            预取帧集合与实际读取窗口必须用同一套公式。一旦上游改了帧数而这里
            仍是 3，预取的集合就会与实际读取错位，__getitem__ 会读到
            torch.empty 的**未初始化显存（脏数据）**——训练照常进行、loss 正常，
            但输入图像是噪声。这类静默错误是最难发现的一种。
        """
        from dataset_v3 import NUM_HI_FRAMES  # 延迟导入，避免模块级循环依赖
        num_hi = NUM_HI_FRAMES

        needed: Dict[Path, Set[int]] = {}
        for clip, frame_idx in dataset.index:
            bucket = needed.setdefault(clip, set())
            for k in range(num_hi):
                bucket.add(max(0, frame_idx - k))
            for k in range(self.history):
                bucket.add(max(0, frame_idx - num_hi - k))
        return needed

    def _estimate_bytes(self, needed: Dict[Path, Set[int]]) -> int:
        """估算预解码后占用的显存字节数（每 clip 按最大帧号+1 分配）。"""
        per_frame = (self.image_size[0] * self.image_size[1] * 3
                     + self.lowres_size[0] * self.lowres_size[1] * 3)
        total = 0
        for frames in needed.values():
            if frames:
                total += (max(frames) + 1) * per_frame
        return total

    def _check_vram_capacity(self, needed: Dict[Path, Set[int]]) -> int:
        """分配前先确认显存装得下，装不下立刻报错。

        为什么必须前置检查而不是"分配时自然会报 OOM"：
            预解码要跑几分钟，OOM 发生在中途会白烧那几分钟算力；
            更重要的是错误信息说不清到底缺多少，容易误判成偶发问题去重试。
        """
        need = self._estimate_bytes(needed)
        if self.device.type not in ("cuda", "npu"):
            return need
        props = get_device_properties(self.device.type, self.device)
        total_bytes = props.total_memory
        # 预留：模型权重 + 训练激活 + 缓存分配器碎片。实测 batch=32 时训练
        # 峰值约 15.2 GB，取 20 GiB 留出余量（宁可报错，也不要跑中途 OOM）。
        reserve = 20 * 1024**3
        if need + reserve > total_bytes:
            raise RuntimeError(
                f"显存不足：预解码需 {need/1024**3:.2f} GiB，"
                f"再预留 {reserve/1024**3:.0f} GiB 给训练，"
                f"合计 {(need+reserve)/1024**3:.2f} GiB > "
                f"显卡总显存 {total_bytes/1024**3:.1f} GiB。"
                "请减少 --val-ratio 或改用更小的 history。")
        return need

    def _probe_gpu_decode(self, needed: Dict[Path, Set[int]]) -> Tuple[bool, str]:
        """用几帧真实数据试一次 nvJPEG，并与 PIL 结果**逐像素**比对。

        为什么要求完全相同（容差 0），而不是"差异不大就接受"：
            torchvision 的 CUDA 解码走 nvJPEG，其 YCbCr→RGB 的舍入与 PIL 不一定一致。
            只要有任何一像素不同，就等于训练数据与之前所有实验不同——而这次改动
            的风险预算是 500 算力点，不能承受"数据悄悄变了"。
            因此策略是：**只有逐像素完全一致才启用 GPU 解码**，否则整体回落到 PIL。
            这样"缓存路径 vs 原始路径"的自检才能以容差 0 通过。
        """
        if self.device.type != "cuda":
            # nvJPEG 是 CUDA 专有通路；npu/cpu/mps 一律回落到 PIL 解码。
            return False, f"device={self.device.type} 无 nvJPEG 解码通路"
        try:
            import torchvision.io as tio  # noqa: F401
        except Exception as exc:
            return False, f"torchvision 不可用: {type(exc).__name__}"
        try:
            # 跨 clip 抽样：只测开头一个 clip 的前几帧不足以证明全局一致。
            # 一旦漏判，训练数据就与既有实验不同 —— 本次改动的风险预算不允许
            # 这种"大概率没问题"。因此在**整个 clip 列表上均匀取 5 个 clip**、
            # 每个取 4 帧，共 20 帧，要求与 PIL **逐像素相同**。
            # 成本约 0.1 s（20 帧解码两次），相对于几分钟的预解码可忽略。
            clips_all = list(needed)
            if len(clips_all) > 5:
                step = len(clips_all) / 5
                picks = [clips_all[int(i * step)] for i in range(5)]
            else:
                picks = clips_all
            probe_paths: List[Path] = []
            for clip in picks:
                for fi in sorted(needed[clip])[:4]:
                    probe_paths.append(clip / "frames" / f"{fi:06d}.jpg")
            if not probe_paths:
                return False, "无可用样本"
            gpu = self._decode_gpu(probe_paths)
            cpu = self._decode_pil(probe_paths)
            if tuple(gpu.shape) != tuple(cpu.shape):
                return False, f"形状不一致 {tuple(gpu.shape)} vs {tuple(cpu.shape)}"
            diff = (gpu.cpu().to(torch.int16) - cpu.to(torch.int16)).abs().max().item()
            if diff != 0:
                return False, f"与 PIL 非逐像素一致（最大差 {diff}/255）"
            return True, "ok"
        except Exception as exc:
            return False, f"{type(exc).__name__}: {str(exc).splitlines()[0][:80]}"

    # -- 解码实现 ------------------------------------------------------------

    def _decode_pil(self, paths: Sequence[Path]) -> torch.Tensor:
        """PIL 解码为 uint8 [N,3,H,W]（CPU）。与 dataset_v3.load_frame 同源。"""
        h, w = self.image_size
        out = np.empty((len(paths), 3, h, w), dtype=np.uint8)
        for i, p in enumerate(paths):
            with Image.open(p) as im:
                arr = np.asarray(im.convert("RGB"), dtype=np.uint8)
            out[i] = np.transpose(arr, (2, 0, 1))
        return torch.from_numpy(out)

    def _decode_gpu(self, paths: Sequence[Path]) -> torch.Tensor:
        """nvJPEG 解码为 uint8 [N,3,H,W]（GPU）。"""
        import torchvision.io as tio

        blobs = []
        for p in paths:
            raw = np.frombuffer(p.read_bytes(), dtype=np.uint8).copy()
            blobs.append(torch.from_numpy(raw))
        decoded = tio.decode_jpeg(blobs, device=self.device)
        # torchvision 0.28：list 入参返回 list[Tensor] 而非批张量，
        # 按张量访问会报 AttributeError，导致 GPU 解码被误判不可用。
        if isinstance(decoded, (list, tuple)):
            decoded = torch.stack(list(decoded))
        return decoded

    def _preload_clip(self, clip: Path, frames: Set[int]) -> None:
        """把一个 clip 需要的帧解码并写入显存张量。"""
        if not frames:
            return
        max_fi = max(frames)
        h, w = self.image_size
        hl, wl = self.lowres_size
        n = max_fi + 1

        hi_t = torch.empty((n, 3, h, w), dtype=torch.uint8, device=self.device)
        lo_t = torch.empty((n, 3, hl, wl), dtype=torch.uint8, device=self.device)

        ordered = sorted(frames)
        chunk = 128
        frames_dir = clip / "frames"

        for start in range(0, len(ordered), chunk):
            part = ordered[start:start + chunk]
            paths = [frames_dir / f"{fi:06d}.jpg" for fi in part]

            if self.decode_mode == "nvjpeg":
                # nvJPEG 解到显存；但低清缩放要走 PIL（与原始实现同源），
                # PIL 只认 CPU numpy，因此必须显式搬回 CPU 再做缩放。
                hi_decoded = self._decode_gpu(paths)
                lo_cpu = self._resize_with_pil(hi_decoded.cpu())
            else:
                hi_decoded = self._decode_pil_threaded(paths)
                lo_cpu = self._resize_with_pil(hi_decoded)

            idx = torch.tensor(part, dtype=torch.long, device=self.device)
            hi_t.index_copy_(0, idx, hi_decoded.to(self.device, non_blocking=True))
            lo_t.index_copy_(0, idx, lo_cpu.to(self.device, non_blocking=True))

        self._hi[clip] = hi_t
        self._lo[clip] = lo_t

    def _decode_pil_threaded(self, paths: Sequence[Path]) -> torch.Tensor:
        """多线程 PIL 解码。Pillow 在 decode/resize 期间释放 GIL，线程能真并行。"""
        def work(p: Path):
            with Image.open(p) as im:
                arr = np.asarray(im.convert("RGB"), dtype=np.uint8)
            return np.transpose(arr, (2, 0, 1))

        if self.decode_threads <= 1 or len(paths) == 1:
            frames = [work(p) for p in paths]
        else:
            with ThreadPoolExecutor(max_workers=self.decode_threads) as pool:
                frames = list(pool.map(work, paths))
        return torch.from_numpy(np.stack(frames, axis=0))

    def _resize_with_pil(self, hi_cpu: torch.Tensor) -> torch.Tensor:
        """把 uint8 [N,3,H,W] 用 PIL BILINEAR 缩到低清，与原始实现完全同源。"""
        hl, wl = self.lowres_size
        arr = hi_cpu.numpy()                      # [N,3,H,W] uint8
        n = arr.shape[0]
        out = np.empty((n, 3, hl, wl), dtype=np.uint8)
        for i in range(n):
            img = Image.fromarray(np.transpose(arr[i], (1, 2, 0)))
            out[i] = np.transpose(np.asarray(img.resize((wl, hl), Image.BILINEAR)),
                                  (2, 0, 1))
        return torch.from_numpy(out)

    # -- 读取 ---------------------------------------------------------------

    def get(self, clip: Path, frame_idx: int, high: bool) -> torch.Tensor:
        """取单帧 uint8 [3,H,W]（已在 device 上）。"""
        table = self._hi if high else self._lo
        tensor = table.get(clip)
        if tensor is None:
            raise KeyError(f"clip 未预缓存: {clip}")
        if not (0 <= frame_idx < tensor.shape[0]):
            raise IndexError(f"帧号越界: {frame_idx}（{clip.name} 共 {tensor.shape[0]} 帧）")
        return tensor[frame_idx]

    def gather(self, clip: Path, frame_indices: Sequence[int], high: bool) -> torch.Tensor:
        """一次取出一个样本窗口的全部帧，uint8 [K,3,H,W]（已在 device 上）。

        为什么用一次 index_select 而不是逐个 get() 再 stack：
            逐个取是 24 次切片 + 1 次 stack = 25 个 CUDA kernel；
            一次索引只需 1 个 kernel。数据侧每省一个 kernel，
            GPU 就少等一次 —— 这正是把利用率拉起来的关键。
        """
        table = self._hi if high else self._lo
        tensor = table.get(clip)
        if tensor is None:
            raise KeyError(f"clip 未预缓存: {clip}")
        n_frames = tensor.shape[0]
        for fi in frame_indices:
            if not (0 <= fi < n_frames):
                raise IndexError(
                    f"帧号越界: {fi}（{clip.name} 共 {n_frames} 帧）")
        idx = torch.as_tensor(list(frame_indices), dtype=torch.long,
                              device=tensor.device)
        return tensor.index_select(0, idx)

    # -- 自检 ---------------------------------------------------------------

    def verify_against_direct(self, dataset, indices: Sequence[int],
                              tol: float = 1e-6) -> float:
        """对比"缓存路径"与"原始解码路径"的产出，返回最大绝对差。

        做法：临时把 dataset.vram_cache 摘掉走原路径，再装回来走缓存路径。
        这样比对的是两条真实代码路径，而不是另写一份参考实现。

        为什么容差用 1e-6 而不是 0：两条路径的像素（uint8）必须完全相同，
        但除以 255 的实现不同 —— 原始路径是 numpy 的真除法，缓存路径是
        torch 在 CUDA 上的 div_（按倒数乘法实现）。实测 126/256 个灰度值
        相差 1 ULP（2^-24 ≈ 5.96e-08），这是舍入噪声，不是数据差异。
        真正改变 1 个像素值造成的最小差是 1/255 ≈ 3.9e-3，比本容差大
        4000 倍，因此 1e-6（≈4 ULP）既能滤掉纯舍入噪声，又远小于任何
        真实数据差异，判定仍然是严格的。
        """
        saved = dataset.vram_cache
        if saved is None:
            # 没挂载就自检 = 两条路径都是原始解码 = 永远返回 0 的假自检。
            # 这种情况必须报错，而不是给出一个"通过"。
            raise RuntimeError(
                "verify_against_direct 要求 dataset.vram_cache 已挂载；"
                "否则比对的双方都是原始解码路径，检查结果无意义。")
        try:
            dataset.vram_cache = None
            refs = [dataset[i] for i in indices]
        finally:
            dataset.vram_cache = saved

        max_diff = 0.0
        for i, ref in zip(indices, refs):
            got = dataset[i]
            for key in ("image_hi", "image_lo"):
                a = ref[key].float().to(got[key].device)
                b = got[key].float()
                # 像素级硬判据：把两条路径的值还原回 uint8 再比，必须逐像素相同。
                # 这才是"训练数据没被改变"的真凭据 —— 任何真实差异（最小
                # 1/255）都会在这里暴露；而 /255 的 1 ULP 舍入噪声在还原时
                # 会被 round 掉，不会误报。
                px_ref = torch.round(a * 255.0).to(torch.int16)
                px_got = torch.round(b * 255.0).to(torch.int16)
                n_bad = int((px_ref != px_got).sum().item())
                if n_bad:
                    worst = int((px_ref - px_got).abs().max().item())
                    raise AssertionError(
                        f"显存缓存像素与原解码不一致：{n_bad} 个像素不同"
                        f"（{key}，最大差 {worst}/255）。这会改变训练数据，已中止。")
                max_diff = max(max_diff, (a - b).abs().max().item())
        if max_diff > tol:
            raise AssertionError(
                f"显存缓存与原始解码浮点值偏差过大：最大差 {max_diff}（容差 {tol}）。"
                "已中止。"
            )
        return max_diff
