# YOLOPX 素材采集侦察笔记（N1/t43 中断抢救）

> **本文件用途**：corpus-hunter 在执行 N1（t43）时被上游服务中断三次，其间完成的**外部素材侦察成果**在此保全。
> 重试时**直接从这里继续**，不要重新检索——检索结果本身是易失的，而这份清单是已核实的。
> 记录时间：2026-09-26 深夜。状态：侦察完成，采集未开始（`data/validation_clips/` 为空目录，`/tmp/corpus/` 为空）。

## 0. 结论先行

- **19 个候选源**已找到并核实过许可与时长，覆盖 8 类工况，可产出约 130~159 帧。
- **雨天素材是真实缺口**：Commons 上真实"雨天**行车**"素材确实稀少，可用的只有 3 个短片段（10s / 6.6s / 20s），来源单一。**报告里必须诚实写明这一点**，不得用冰雪或雾天冒充雨天。
- 分辨率：所有源均为 **16:9**（1920×1080 / 2560×1440 / 3840×2160 / 1280×720 / 640×360），可直接 `scale=1280:720`，无需补边（补黑边会污染模型输入）。

## 1. 候选源清单（14 主源 + 5 补充）

| ID | 源 | 工况 | 许可 | 时长 |
|---|---|---|---|---|
| kr_wonju | 2020-04-16 원주시 도로주행 | day_city | CC0 | 182s |
| md_annapolis | Driving from Broad Creek to Jennifer Road (Annapolis) | day_city | CC BY-SA 4.0 | 300s |
| md_i495 | Driving eastbound on I-495 | day_highway | CC BY-SA 4.0 | 300s |
| md_i270 | Driving southbound on I-270 | day_highway | CC BY-SA 4.0 | 300s |
| wv_us33 | US 33 in West Virginia | curve_day | CC BY 3.0 | 60s |
| xz_109 | 行驶在109国道昆仑山段 | curve_day | CC BY-SA 4.0 | 148s |
| no_night | Cars driving at night | night | CC BY 3.0 | 160s |
| bb_night_br | Beachfront Night Traffic Time Lapse | night | CC BY 3.0 | 13s |
| tunnel_cave | Bad traffic meeting in cave tunnel | tunnel | PD | 97s |
| de_tomitz | Fahrt durch den Tomitztunnel 1 | tunnel | CC BY-SA 4.0 | 26s |
| si_fog | On the Road - Foggy Ljubljana | fog_lowcontrast | CC BY 3.0 | 1559s |
| cn_sunset | 肃北 肃阿公路之日落大道 | backlight | CC BY-SA 4.0 | 77s |
| ca_i110rain | Interstate 110 during atmospheric river | rain_wet | CC BY 4.0 | 10s |
| ca_wilshire | Intersection of Wilshire Blvd and S Figueroa | rain_city | CC BY 4.0 | 6.6s |
| cz_freezy | Freezy Traffic | snow_ice | CC BY 3.0 | 20s |
| jp_kumamoto | 2026年熊本地震 日奈久IC | congestion | CC BY-SA 4.0 | 38s |
| okc_i235 | I-235 North OKC Full Timelapse | congestion | CC BY-SA 4.0 | 125s |
| cz_jizni | Jižní spojka, 2010-07 | congestion_hw | CC BY-SA 4.0 | 19s |

## 2. 工况目录映射（8 类，按验收要求，每源只归一个主目录避免重复）

| 工况目录 | 源 | 目标帧数 |
|---|---|---|
| `day_city` | kr_wonju, md_annapolis | 12 + 10 |
| `day_highway` | md_i495, md_i270, wv_us33 | 10 + 8 + 12 |
| `night` | no_night, bb_night_br | 12 + 6 |
| `tunnel` | tunnel_cave, de_tomitz | 12 + 8 |
| `rain_wet` | ca_i110rain, ca_wilshire, cz_freezy | 6 + 5 + 6 |
| `backlight_lowcontrast` | cn_sunset, si_fog | 12 + 10 |
| `curve` | xz_109 | 10 |
| `congestion` | jp_kumamoto, okc_i235, cz_jizni | 8 + 6 + 6 |

合计约 **159 帧**（验收要求 80~200）。

## 3. 技术方案（关键决策，已验证思路）

### 3.1 不要整file下载——用 ffmpeg 分段拉取
部分源体积很大（如 md_i495：300s @ 1280×720 ≈ 163MB），**远超单视频 50MB 限制**。
正确做法：用 ffmpeg 的 HTTP 输入 + `-ss`/`-t` 只拉取需要的窗口，落盘到 `/tmp` 的**受限片段**：

```bash
mkdir -p /tmp/corpus
ffmpeg -ss <start> -i "<URL>" -t 60 -c copy -y /tmp/corpus/<id>.webm
# 抽帧（输出统一 1280×720）
mkdir -p data/validation_clips/<工况>
ffmpeg -i /tmp/corpus/<id>.webm -vf "fps=<N/时长>,scale=1280:720" -q:v 2 \
       data/validation_clips/<工况>/<id>_%03d.jpg
rm -f /tmp/corpus/<id>.webm        # ← 抽帧后立即删除，这是硬要求
```

- `-c copy` 输出 `.webm` 最稳（源多为 VP9/AV1 webm，转 mp4 copy 可能失败）
- 抽帧间隔要够大，**避免同秒重复画面**
- 每个源的窗口起点均匀分布在其时长内

### 3.2 码流档位选择（控制体积）
- 从 Commons `derivatives` 里挑 **height ≥ 720 且 height 最小**的档（优先 1280×720），同高则取 bandwidth 最小
- 体积估算 `bw × 时长 / 8`，若 >45MB 则缩短窗口

### 3.3 分辨率处理
所有源均为 16:9 → **直接 `scale=1280:720` 拉伸**，不要用 `pad` 补边（黑边/灰边会污染模型输入，M2 的判据里专门提过灰边问题）。

## 4. 纪律与红线（重申）

- 视频**只下 `/tmp`**（`/tmp/corpus/`），抽帧后立即 `rm`；总量 ≤300MB；结束时报告实际占用并确认无残留
- **禁用** `data/mac_shots`、`data/watch`、`data/raw_clips`——经实测都是本项目 **UI 截屏**，不是行车画面，别拿来充数
- **逐帧记录来源**：`_sources.csv` 含 帧名 / 工况 / 来源 URL / 许可 / 抽帧时间点，缺一字段视为不达标
- 来源不明或版权不清一律不用；**不得编造 URL 或伪造素材**
- 不删除、不覆盖用户任何既有文件；不改任何源码/模型/vendored 仓库

## 5. 续做指引（给下一次 attempt）

1. 先**验证 ffmpeg 可用**（`which ffmpeg`），不可用则报告，不要自己装
2. 拿**一个源**（建议 kr_wonju，CC0、体积小）跑通完整管线，确认输出确为 1280×720
3. 批量执行，**边做边落盘**：
   - 每完成一个源，立即把帧写入 `data/validation_clips/<工况>/`
   - 每完成一个源，立即**追加**（append）一行到 `data/validation_clips/_sources.csv`
   - 遵守 CSV 规范：字段内含逗号必须加引号，否则表结构会被破坏
4. 尽量**保持工具调用简短**（减少被上游中断的暴露面）
5. 最后写报告：`docs/文档库/探索文档/yolopx-网络素材采集报告.md`
   - 必含：检索过程、每源许可、各工况实际帧数、与现有 4 张图的差异、**诚实列出的未覆盖工况**

## 6. 已知缺口（必须写进报告，不得粉饰）

- **真实雨天行车素材只有 3 个短片段**（10s + 6.6s + 20s），来源单一；`cz_freezy` 是冰雪路面，**不能算雨天**
- `si_fog` 是雾天低对比，与"逆光"不是一回事，不宜混为一类
- 隧道素材只有 2 个源（97s + 26s），其中 `tunnel_cave` 是洞内堵车场景
- 所有素材均为**境外道路/右舵或左舵各异**，与《异环》游戏域不完全一致——这是同域性上的固有局限，报告需说明

## 7. 体积控制的正确判据（第二次侦察发现，很重要）

**关键结论：决定 60s 截取体积的是「带宽」，不是「全文件大小」。** 用 `-ss/-t` 截取时只拉那一段的码流。

按此口径重算（`体积 ≈ 全文件大小 ÷ 总时长 × 截取秒数`）：

| 源 | 全文件 | 时长 | 带宽 | 截 60s 约 |
|---|---|---|---|---|
| si_fog | 276.9MB | 1558.6s | 0.142 MB/s | **8.5MB ✓** |
| md_i495 | 163.3MB | 300.5s | 0.543 MB/s | **32.6MB ✓** |
| no_night | 113.6MB | 159.9s | 0.710 MB/s | **42.6MB ✓（勉强）** |
| kr_wonju | 254.5MB | 182.4s | 1.395 MB/s | 83.7MB ✗ 超限 |
| wv_us33 | 71.5MB | 60s | 1.190 MB/s | 71.5MB ✗ 超限 |
| cz_krakow | 4236MB | 2702s | 1.570 MB/s | 94MB ✗ 超限 |
| xz_109 | 1776MB | 148s | **12.0 MB/s** | 720MB ✗✗ 严重超限 |

→ **统一使用「转码档位」最安全**，并优先选 **1280×720 转码**（分辨率正好，体积小）。
→ 对高码率源（尤其 xz_109、cz_krakow、kr_wonju、wv_us33）**必须**走转码档，禁止直取原始 URL。
→ 部分源（如 si_fog）可能**没有 720p/1080p 转码**，只有原始 URL——此时按带宽估算，只要截取段 ≤50MB 即可用原始 URL。

### 7.1 执行前必须做的一件事
**精确列出每个候选源的全部转码档位**（width/height/bandwidth），再按「height≥720 且最小、同高取 bw 最小」选定。不要凭记忆或估算选档。
