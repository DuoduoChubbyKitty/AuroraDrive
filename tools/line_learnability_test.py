# -*- coding: utf-8 -*-
"""
决定性实验: 模型能否从【原始像素】学会预测辅助线位置? 分辨率要多少?

用户的质疑(正确): 红点图是【脚本分割】的结果, 证明的是"脚本能抠出线",
                 不等于"模型能从原始像素学会它"。必须实测。

实验设计
--------
  输入  : 原始帧缩到 NxM RGB(不做任何颜色过滤/掩膜/预处理)
  输出  : line_now (归一化横向偏移, 来自脚本标签)
  模型  : 极小 CNN(手写, 无需 torch)
  对照  : (a) 均值基线     —— 永远猜训练均值
          (b) 打乱标签对照 —— 同样网络 + 随机置换的标签(检验是否只是过拟合)
  变量  : 分辨率 64x36 / 128x72 / 192x108  —— 直接回答"要不要提高分辨率"

判据
----
  验证集 MSE < 均值基线 MSE 且 < 打乱标签对照 MSE  → 像素里真有可学信号
  随分辨率升高误差下降                             → 提高分辨率有收益
"""
import numpy as np, glob, os, csv, sys
from PIL import Image

sys.path.insert(0, '/Users/dupi/Desktop/自动驾驶系统/tools')


def load_labels():
    """收集所有 (帧路径, line_now) 对。"""
    pairs = []
    for csvf in glob.glob('/tmp/harvest*/aid*.csv') + glob.glob('/tmp/harvest/aid*.csv'):
        if '.csv.csv' in csvf:
            continue
        base = os.path.basename(csvf).replace('.csv', '')
        if not base.startswith('aid'):
            continue
        d = os.path.dirname(csvf)
        for r in csv.DictReader(open(csvf, encoding='utf-8-sig')):
            if r.get('found') != '1':
                continue
            v = r.get('line_now')
            if v in ('', 'None', None):
                continue
            p = os.path.join(d, base, r['file'])
            if os.path.exists(p):
                pairs.append((p, float(v)))
    return pairs


def load_images(pairs, W, H):
    X, Y = [], []
    for p, v in pairs:
        try:
            im = Image.open(p).convert('RGB').resize((W, H), Image.BILINEAR)
        except Exception:
            continue
        X.append(np.asarray(im, dtype=np.float32) / 255.0)
        Y.append(v)
    return np.array(X), np.array(Y, dtype=np.float32)


# ---------- 手写 CNN ----------
class TinyCNN:
    def __init__(self, seed=42):
        rng = np.random.RandomState(seed)
        def he(fi, fo, k):
            return (rng.randn(k, k, fi, fo) * np.sqrt(2.0 / (k * k * fi))).astype(np.float32)
        self.P = {
            'w1': he(3, 12, 3), 'b1': np.zeros(12, np.float32),
            'w2': he(12, 24, 3), 'b2': np.zeros(24, np.float32),
            'w3': (rng.randn(24, 1) * 0.1).astype(np.float32), 'b3': np.zeros(1, np.float32),
        }
        self.mz = {k: np.zeros_like(v) for k, v in self.P.items()}

    @staticmethod
    def _conv(x, w, b):
        N, H, W, C = x.shape
        k = w.shape[0]
        Ho, Wo = H - k + 1, W - k + 1
        out = np.zeros((N, Ho, Wo, w.shape[3]), np.float32)
        for i in range(k):
            for j in range(k):
                out += x[:, i:i + Ho, j:j + Wo, :] @ w[i, j]
        return out + b

    def forward(self, x):
        c1 = np.maximum(self._conv(x, self.P['w1'], self.P['b1']), 0)      # (N,H1,W1,12)
        N, H1, W1, C1 = c1.shape
        H2, W2 = H1 // 2, W1 // 2
        r1 = c1[:, :H2 * 2, :W2 * 2, :].reshape(N, H2, 2, W2, 2, C1)
        pool_mask = (r1 == r1.max(axis=(2, 4), keepdims=True))
        # 每格只保留第一个最大值, 避免重复计数
        first = np.zeros_like(pool_mask)
        flat = pool_mask.reshape(N, H2, 4, W2, 4, C1) if False else None
        p1 = r1.max(axis=(2, 4))                                           # (N,H2,W2,12)
        c2 = np.maximum(self._conv(p1, self.P['w2'], self.P['b2']), 0)     # (N,H3,W3,24)
        g = c2.mean(axis=(1, 2))                                           # (N,24)
        pred = g @ self.P['w3'] + self.P['b3']
        return pred, (c1, r1, pool_mask, p1, c2, g, (H1, W1, H2, W2, C1))

    def backward(self, x, y, cache):
        c1, r1, pool_mask, p1, c2, g, dims = cache
        H1, W1, H2, W2, C1 = dims
        N = x.shape[0]

        pred = g @ self.P['w3'] + self.P['b3']
        d = (pred - y) * 2.0 / N                      # dL/dpred
        gW3 = g.T @ d
        gb3 = d.sum(0)
        dg = d @ self.P['w3'].T                       # (N,24)

        dc2 = np.broadcast_to(dg[:, None, None, :], c2.shape).copy()
        dc2[c2 <= 0] = 0

        # conv2 backward
        k = 3
        Ho, Wo = p1.shape[1] - k + 1, p1.shape[2] - k + 1
        gp1 = np.zeros_like(p1)
        gW2 = np.zeros_like(self.P['w2'])
        gb2 = dc2.sum(axis=(0, 1, 2))
        for i in range(k):
            for j in range(k):
                gp1[:, i:i + Ho, j:j + Wo, :] += dc2 @ self.P['w2'][i, j].T
                gW2[i, j] = np.tensordot(p1[:, i:i + Ho, j:j + Wo, :], dc2,
                                         axes=([0, 1, 2], [0, 1, 2]))

        # maxpool backward: 把梯度放回每格最大值处
        gr1 = np.zeros_like(r1)
        gmax = pool_mask.astype(np.float32)
        cnt = gmax.sum(axis=(2, 4), keepdims=True)
        gmax = gmax / np.maximum(cnt, 1.0)             # 均分(等价 argmax 的稳版本)
        gr1 = gmax * gp1[:, :, None, :, None, :]
        dc1 = gr1.reshape(N, H1, W1, C1)

        # conv1 backward
        Ho, Wo = x.shape[1] - k + 1, x.shape[2] - k + 1
        gW1 = np.zeros_like(self.P['w1'])
        gb1 = dc1.sum(axis=(0, 1, 2))
        for i in range(k):
            for j in range(k):
                gW1[i, j] = np.tensordot(x[:, i:i + Ho, j:j + Wo, :], dc1,
                                         axes=([0, 1, 2], [0, 1, 2]))
        return {'w1': gW1, 'b1': gb1, 'w2': gW2, 'b2': gb2, 'w3': gW3, 'b3': gb3}

    def step(self, x, y, lr):
        pred, cache = self.forward(x)
        gr = self.backward(x, y, cache)
        for k in self.P:
            self.mz[k] = 0.9 * self.mz[k] + 0.1 * gr[k]
            self.P[k] -= lr * self.mz[k]
        return float(((pred - y) ** 2).mean())


def run(res, pairs, epochs=80, lr=2e-3, bs=16, shuffle_labels=False, seed=42):
    W, H = res
    X, Y = load_images(pairs, W, H)
    if len(X) < 20:
        return None
    rng = np.random.RandomState(0)
    idx = rng.permutation(len(X))
    nval = max(4, len(X) // 5)
    val, tr = idx[:nval], idx[nval:]
    Xtr, Ytr = X[tr], Y[tr].reshape(-1, 1)
    Xva, Yva = X[val], Y[val].reshape(-1, 1)

    if shuffle_labels:
        Ytr = Ytr[rng.permutation(len(Ytr))]

    net = TinyCNN(seed)
    trng = np.random.RandomState(7)
    for ep in range(epochs):
        perm = trng.permutation(len(Xtr))
        for i in range(0, len(Xtr) - bs + 1, bs):
            b = perm[i:i + bs]
            net.step(Xtr[b], Ytr[b], lr)

    pv, _ = net.forward(Xva)
    pt, _ = net.forward(Xtr)
    return {
        'res': f'{W}x{H}', 'n': len(X), 'ntr': len(Xtr), 'nva': len(Xva),
        'val_mse': float(((pv - Yva) ** 2).mean()),
        'tr_mse': float(((pt - Ytr) ** 2).mean()),
        'base_mse': float(((Yva - Ytr.mean()) ** 2).mean()),
        'corr': float(np.corrcoef(pv.ravel(), Yva.ravel())[0, 1]) if len(Xva) > 2 else 0.0,
    }


if __name__ == '__main__':
    pairs = load_labels()
    print(f"══ 数据 ══")
    print(f"  有 line_now 标签的帧: {len(pairs)}")
    if len(pairs) < 20:
        print("  样本太少, 退出"); sys.exit(1)

    print(f"\n══ 实验1: 分辨率影响（原始像素 → line_now）══")
    print(f"{'分辨率':>10} {'样本':>5} {'训练MSE':>9} {'验证MSE':>9} {'均值基线':>9} {'提升':>7} {'相关系数':>8}")
    results = []
    for res in [(64, 36), (128, 72), (192, 108), (256, 144)]:
        r = run(res, pairs)
        if r:
            results.append(r)
            imp = (1 - r['val_mse'] / max(r['base_mse'], 1e-9)) * 100
            print(f"{r['res']:>10} {r['n']:>5} {r['tr_mse']:>9.5f} {r['val_mse']:>9.5f} "
                  f"{r['base_mse']:>9.5f} {imp:>6.1f}% {r['corr']:>+8.3f}")

    print(f"\n══ 实验2: 打乱标签对照（排除过拟合假象）══")
    sh = run((128, 72), pairs, shuffle_labels=True)
    real = next((r for r in results if r['res'] == '128x72'), None)
    if sh and real:
        print(f"  真实标签 : 验证MSE {real['val_mse']:.5f}  相关系数 {real['corr']:+.3f}")
        print(f"  打乱标签 : 验证MSE {sh['val_mse']:.5f}  相关系数 {sh['corr']:+.3f}")
        ratio = real['val_mse'] / max(sh['val_mse'], 1e-9)
        print(f"  → 真实/打乱 = {ratio:.3f}  (>1 说明真实更好)" if ratio > 1 else
              f"  → 真实/打乱 = {ratio:.3f}  (<1 说明真实【更差】, 像素里没学到东西)")

    print(f"\n══ 结论 ══")
    if results:
        best = min(results, key=lambda r: r['val_mse'])
        ok = real and real['corr'] > 0.3 and real['val_mse'] < real['base_mse'] * 0.9
        if sh and real and real['val_mse'] > sh['val_mse']:
            ok = False
        print(f"  最佳分辨率: {best['res']}  验证MSE {best['val_mse']:.5f}")
        if ok:
            print("  ✓✓ 原始像素里【确实有可学的信号】——模型能学会预测线的位置")
            print("     → 不需要额外提高分辨率, 180x320 的架构可用")
        else:
            print("  ✗  模型未能从原始像素学到线位置 → 需要提高分辨率或改方案")
