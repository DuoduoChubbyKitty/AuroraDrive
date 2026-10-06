# 为什么要做成现在这样，以及另一个模型必须怎么做

这份文件不是设计展览。它是给下一个来写代码的模型用的施工说明。先把这次 20 个问答钉死，再讲为什么不能做成别的样子，最后按用户真正会碰到的顺序写怎么做。不要再重新选型，不要再发明一套录制引擎，不要再把 API Key 塞进钥匙串，不要再逐帧打 Agnes。

> 【2026-09-19 落地状态核对】（供实现者进场前对照，正文施工要求不变）
> - **未动工**：GenericAgent vendor（`Vendor/` 现仅有 MetalGoose，无 `Vendor/GenericAgent`）、MaaFramework C API 桥接与 HybridController（Sources 中无 `MaaTasker*` / `MaaCustomController` 代码，仅 `tools/maa_roi_offset.py` 注释提及）、`events.csv` 鼠标事件流、10 秒 Agnes 监视时钟
> - **已成立**：项目根 `.llm-key-notebook.md`（gitignored）存在；`data/raw_clips/` 目录在位；MaaNTE/ 框架本体仍本地保留
> - **定位澄清**：文中"技能执行改走 Maa"是 9-17 时的最大改动方向；截至 2026-09-19 项目实际定位收敛为 **Maa 只做工具（ROI/模板/任务定义参考），不整体接管项目**——主力执行通道仍是 Swift `AgentSkillCenter.runSkill`（15 已移植 + 3 待移植，见 `docs/文档库/探索文档/ai-agent-panel.md`），MaaNTE 侧产出为 250 节点 ROI override（`build/maa_pipeline_override.json`）+ 24 个待采模板。Maa 任务直接调用的集成待重新排期（待核实：是否已另立方案）
> - 设置页 Agnes 示例（"Agnes（当前默认）"，AIAgentPanel.swift:2228）属"教用户配置"入口，不等于"内置默认密钥"，与本文"三个零"不冲突

> **模型厂商那条线的规则已单独成文：`docs/文档库/探索文档/模型厂商关系与推荐规则.md`。**
> 推荐谁说、推荐谁、说多狠、什么时候停、哪里不许写、Agnes 到底算什么——全在那里。这份文件里凡是涉及厂商推荐和 Agnes 定位的句子，都以那份为准。

---

用户已经当面校准过理解。下面 20 条是最终口径，跟旧稿冲突时以这里为准。

大脑落在 GenericAgent（Python 侧载进程）。Swift 只做截图、键鼠注入、录制、以及现有技能执行。GenericAgent 不是二次元游戏专用框架，这不算违约：游戏专用手脚继续用现有 MaaNTE 移植技能，GenericAgent 只当通用大脑。侧边栏可以重做布局，但必须还是侧边栏，不能改成独立大窗。接管按钮不放在侧边栏里，也不做系统 alert：它钉在左侧那块又宽又扁的游戏预览画面最顶上，中间一个非常大的按钮。录制主路径是 AI 卡住后主动请求接管，用户点了那个大按钮才开始录；同时也要留「我来演示一次」，让用户不经过卡住也能主动教。点接管之后系统必须自动打开专家模式并开始录制，用户不许再点第二下。录的东西不能只有现有 `controls.csv` 的 steer/throttle/brake：必须同时记下帧、键盘按下释放、鼠标点击坐标和时间戳，现有 CSV 不够，要扩。事后理解只许把多帧拼成一张宫格图一次性扔给**事后分析用的那双眼睛**（120 帧已经用 Agnes 实测能过），不许逐帧调 API。视觉模型只负责语义（这是什么操作），坐标和按键从录制文件读，不许让模型猜坐标。日常执行不是每一步都看图，而是每 10 秒截一次图丢给 **Agnes**（监视用的那个模型），专门看它有没有干蠢事。**规划和监视是两回事、两个模型**：规划走主模型，监视走 Agnes。配置不是给开发者看的控制台，也不是游戏新手教程。这是给**正常使用本 App 的人**：第一次打开侧边栏想对话时，项目里还没有模型、没有 Key。这时侧边栏里顶上来的不是 GenericAgent，而是**管理员**（就是前面说的引导员，同一个角色，不要做成两套人）。模型也必须用户自己配，但**不许让用户自己去找**：乱填一个网上看来的端点会把看屏、宫格、接管全带进坑里。正确路径是管理员带着去注册，用户把密钥交给管理员（可以贴在对话里，管理员收下）。**Agnes 不是内置默认密钥，项目里没有写死的 Agnes Key。** 正常要用户自己接**两个模型**：主模型（规划用）+ Agnes（监视 + 事后分析用）。Agnes 同时是备用模型——用户如果强行要用 Agnes 来当主模型，管理员才带用户去做这件事。管理员收下密钥后必须当面确认三件事：这是哪一家、这是什么模型、这把是主模型还是 Agnes 那一侧（监视 / 事后分析）。用户说对了，管理员自己去测密钥能不能连通，测通才写进小本本。用户说不是、或者说不知道，管理员继续带，不许偷偷用一个默认模型冒充已经配好。配完、确认完、测通了，管理员退下，真正的大脑才上场。API 一旦没了（文件空了、401、额度没了），管理员再顶上，不许让用户对着空白输入框发呆。**Agnes 配不上、测不通、或用户根本没配 Agnes 时，管理员必须主动提醒**：「监视和事后分析现在做不了（每 10 秒看屏、演示学会都缺），要不要我带你配 Agnes？它是备用模型，也可以先拿来当监视和事后分析用；规划另外配一个主模型。」不要静默让监视和事后理解坏掉。用户也可以随时主动召唤管理员：输入框打 `/` 弹出命令列表，命令有很多种，**最顶上第一条永远是「召唤管理员」**。点它或输入 `/管理员` 就立刻切到管理员说话，不管当前 GenericAgent 在不在干活。项目不内置任何开发者 Key。管理员本身不需要用户先配 Key：走 Pollinations 的 GPT-OSS 20B（`https://text.pollinations.ai/openai`，模型字段 `openai`，Key 空着也能聊）。它看不见图，只负责把人教会配模型、确认用途（主模型 / Agnes 那一侧）、并测试能不能连通。API Key 只许放项目根目录 `.llm-key-notebook.md`，绝对不用 macOS 钥匙串。现有 `AgentLoop` / `RealLLMPlanner` 整条规划链路换掉，但 `AgentSkillCenter.runSkill` 不动。学会的 SOP 写进 GenericAgent 的 `memory/<任务名>_sop.md`。这套东西只服务《异环》。现有钓鱼/领奖/登录等技能先留着：能用就不要重写，不能用再丢；这份文档写作时没有对着正在跑的《异环》做通关实测，实现阶段必须自己验证，不能把「代码里有 execute 分支」当成「游戏里一定能跑」。卡住判定要两套同时生效：模型自己可以说「我不会」，失败计数到底线也必须弹接管。

---

为什么必须是 GenericAgent 当大脑，而不是继续打补丁给现在的 `AgentLoop`。

现在的规划器在 `Sources/AuroraDrive/AgentLoop.swift`，真正发请求的是 `AgentSkillCenter.callLLM`（`AIAgentPanel.swift` 里）。它走 OpenAI 兼容的 tool calling，但 messages 里只有一段硬编码纯文本：「你是异环游戏自动化助手。用提供的工具完成用户任务。一次只调用一个工具。不要解释，不要输出 JSON 文本。」模型完全看不到游戏画面。这就是用户说「验证了半天没法用」的那套东西。在这上面塞一张图不是小补丁：没有记忆分层、没有「成功后把步骤写成 SOP」、没有「卡住问人」、没有浏览器去查攻略。继续打补丁会把不可用的规划器和以后真正能看图的系统缠在一起。所以规划链路整段替换，技能执行通道不动。`AgentSkillCenter.runSkill(_:source:)` 是人类点按钮和 AI 下指令共用的入口，`source` 只有 `.human` 和 `.ai`。任何新大脑要动手，只能调这个函数，不许再写一套按键逻辑。

为什么 GenericAgent 够格，却不能幻想它已经会看录屏。它不是 MAA 生态，MIT 协议，Agent Loop 大约一百行，记忆分五层（L0 元规则 / L1 索引 / L2 环境事实 / L3 技能 SOP / L4 会话归档），有 `do_start_long_term_update` 把验证成功的步骤结晶成文件，有 `ask_user`，超过大约 180 轮会强制问人，有真实浏览器 `TMWebDriver.py`，有 macOS 键鼠 `memory/macljqCtrl.py`。这些是读过源码的事实。它没有的能力同样是事实：`vision_api.template.py` 只吃单张图，没有视频解码，主循环默认纯文本，学习方式是自己试错再记笔记，不是看人类演示一遍就会。所以「看演示学会」不能指望上游 GenericAgent 自带，必须由 AuroraDrive 录完、拼宫格、问 Agnes、再把 SOP 写进它的 `memory/`。上游仓库按 `lsdefine/GenericAgent` 理解；实现时要 vendor 进本仓库，不要依赖某次会话里 `/tmp/GenericAgent` 那种临时目录，那个路径随时会没。

为什么 Agnes 是监视和事后分析那一侧，为什么规划是另一个模型，为什么 Pollinations 不能当眼睛。

两个模型分工不能混：**主模型管规划**（想下一步干什么），**Agnes 管监视**（每 10 秒看一次屏幕，判断有没有跑偏、弹窗、卡死）**和事后分析**（演示结束的宫格理解，总结成技能）。Agnes 同时是**备用模型**——主模型挂了、或用户强行要用 Agnes 当主模型，管理员才带用户去配这件事。**Agnes 不是内置默认密钥**：仓库和安装包里不许写死 Agnes Key。

同一套测试图当场打过。Agnes 端点 `https://api.agnes-ai.cn/v1`，模型 `agnes-2.5-flash`。单图能认出红苹果。三帧拼在一起能按 FRAME 1/2/3 分开说，不打乱顺序。120 帧宫格（10 列 × 12 行，大约 1500×2040，PNG 约 1.4MB）一次请求 HTTP 200，大约 25.8 秒；测试图其实是三张图循环拼的，它说这是循环模式，没有编连续剧情。这说明它在看图，所以**能当监视的眼睛，也能做事后分析**。

Pollinations `https://text.pollinations.ai/openai`、`model=openai` 返回体里的真实模型是 `gpt-oss-20b`。单图直接说看不到图片。同一张 120 帧宫格它编了 F8 光照变化、F22 摄像机抖动，结尾自己写「以上仅为示例」。接口不报错不等于会看图。所以 Pollinations 只许当管理员的免费嘴，不能当监视，也不能当事后分析。

两个模型的硬条件：用户自己的、测得通、**能看图（多模态）**。只通文本、不通图片的密钥，管理员必须拒绝，并说明原因。用户若已经有别家的多模态 Key，管理员可以收下，但必须先问清楚「这是哪家、模型全名叫什么、当主模型还是 Agnes 那一侧」，确认后再测；测失败就说失败，不许换一个没确认过的端点硬试。用户说「把这个当作主模型」，管理员复述确认后再测一遍连通和看图。监视和事后分析可以是 Agnes 一把，也可以是用户指定的别家；不管哪家，没有可用的事后分析时管理员必须提醒，不要等用户点完「结束演示」才发现没眼睛。

为什么不能帮用户自动注册账号，也不能把开发者 Key 打进安装包，但也不能甩一张开发者表单。主流服务商都要人工开户。程序批量注册违 ToS。共享开发者 Key 被滥用时，封号和责任会落到 Key 注册人身上。所以 Key 必须是用户自己的。可用户打开 App 时往往什么都不知道：没有模型，侧边栏却已经在那，人想说话。正确做法不是把 Base URL / model / max tokens / 超时摊在脸上让人填（那是开发者体验），也不是丢一句「你自己去找个视觉 API」让人满世界搜（那样一定会配错）。正确做法是侧边栏里先出现管理员，用对话带人走完：「要干活得接两个模型：一个主模型管规划（想下一步干什么），一个 Agnes 管监视（每 10 秒看一次屏）和事后分析（演示学会）。Agnes 也是备用模型，你要拿它当主模型也行，那是你的决定，不是我替你定。→ 打开这个链接 → 登录 → 复制 Key → 把密钥发给我 → 我复述：这把是当【主模型 / Agnes 那一侧 / 两件事都用】的，你确认吗？ → 你说确认之后我去测能不能连通、能不能看图 → 通了才保存。」密钥是交给管理员的，不是让用户自己去翻高级设置填网关。测通并确认之后管理员退出，日常只剩聊天和技能。用户如果实在不知道点哪里，就继续问管理员，管理员必须能把注册页步骤讲完，不能把人推出去自己找眼珠子。用户随时可以说「把这个当作主模型」或「这个只当监视和事后分析」，管理员确认后改用途。会改网关的人可以再打开「高级」——那是可选，不是第一次见面必须看见的墙。管理员用的模型必须零 Key：Pollinations GPT-OSS 20B。它不能看图，所以引导阶段不许假装已经能看游戏画面。主模型还没经用户确认并测通之前，看屏、接管全部禁用。Agnes 没有或测不通时，接管演示还可以录，但结束演示后管理员必须提醒「监视和宫格理解做不了」，不要假装还在监视、也不要假装已经学会。

管理员不是只能在没 Key 时出现。日常已经配好之后，用户随时可以在输入框打 `/`。一打 `/`，输入框上方（或输入框里）弹出命令面板，列出很多命令，**排序上第一条必须是「召唤管理员」**，其余命令（停止、状态、演示、帮助……）排在后面。选中第一条或输入 `/管理员`：立刻打断当前任务对话，切到管理员。管理员上来先报自己能管的事：配主模型、配 Agnes 那一侧、收密钥、确认模型、改钥匙用途、测连通和能不能看图、看小本本是不是空了。密钥测试是管理员的活，不是用户自己去 curl。测分两档：先发一条不含图的最小聊天请求，确认 Key 本身通；两个模型还必须再发一条带小图的请求，确认真的能看图。纯文本通、看图失败的，不能当主模型，也不能当监视 / 事后分析，管理员要说清楚。HTTP 2xx 且能解析出助手文本才算连通；401/403 说密钥不对或没权限；超时、DNS、空响应说联不上；模型名不对就根据报错让用户再确认模型。测的结果必须用人话写在侧边栏里，不许只打一个 HTTP 状态码。用户说「把这个当作主模型」时，管理员先复述确认，再跑这两档测试，通过才改小本本里的用途字段。现有 `sendUserMessage` 没有 `/` 命令面板，实现时要加；以 `/` 开头的输入先走命令解析，不要当「帮我钓鱼」丢给 GenericAgent。

为什么 Key 必须在项目根 `.llm-key-notebook.md`，而不是 Application Support，更不是钥匙串。用户明确禁止钥匙串：启动路径读 Keychain 是启动异常根因。现有 `AgentSettings.notebookURL` 写在 `~/Library/Application Support/AuroraDrive/llm-key-notebook.txt`，跟用户说的「小本本放项目文件夹」不是同一个地方。项目根已经有 `.llm-key-notebook.md`（gitignore，禁止提交），表里是 API Key / Base URL / 默认模型。新系统读这一份，不要再读钥匙串，也不要再发明第三份。实现时如果 GUI 还在走 `AgentSettings.load()`，必须改到读这个文件，否则用户填了窗口却被旧路径覆盖。文件权限保持只有当前用户能读。文档和日志里引用 Key 必须掩码。

为什么日常看屏是每 10 秒一次，而不是每步都看，也不是只在录完以后看。看屏走 **Agnes**。Agnes 实测大约每分钟 24 次请求限额。每步都看图，技能循环（钓鱼抛竿、闪避）会把额度打爆，还会把延迟叠到没法玩。只在录完以后看，又看不见「它正在干蠢事」。每 10 秒一次等于每分钟 6 次，占额度大约四分之一，剩下的留给卡住后的核对和录完那一次宫格。这 10 秒一次是**监视**，不是规划：问的是「当前任务是什么、它声称在做什么、画面上有没有跑偏、弹窗、卡死、明显点错」。监视判定跑偏，可以触发接管。**规划不在这条路径上**，规划走主模型，按需调用。监视不要把 120 帧宫格每 10 秒发一次，那既慢又贵。宫格只用于演示结束之后的事后理解，同样走 Agnes。

为什么坐标不能让 Agnes 填。宫格里每格只有大约 150×150，按钮只有几个像素，模型报的坐标会漂。现有 `RecordEngine` 的 `controls.csv` 表头是 `t_sec,frame,steer,throttle,brake`，这是给驾驶模仿学习用的连续量，没有鼠标点击，也没有 F3/ESC 这种键。`KeyboardMonitor` 能听全局键盘和按住时长，但只服务专家模式把 WASD 换成比例标签，不会把每次按键写成事件日志。`MouseController` 只会注入点击，不会记录用户点了哪里。所以接管录制必须新增事件流（键盘 + 鼠标），Agnes 只输出「F8 附近点了传送」这种语义，实现者用帧号去对事件流里的真实点。两套数据缺一不可：没有语义就不知道为什么要点，没有事件流就点不准。

为什么接管按钮要钉在预览最顶上。用户不要侧边栏里一个普通按钮，也不要盖住整块游戏的模态。左侧预览是 `GameViewportView`（`AuroraDriveApp.swift` 里标注为游戏画面叠加区），已经有顶上的锁定提示、左上小地图、左下 REC。新的接管条占预览最顶上一整行，中间放最大的按钮，文案要一眼能懂，例如「接管」。AI 请求时才出现主路径按钮；「我来演示一次」可以常驻成次一级入口，但不要跟卡住时那个大按钮抢视觉。点下去之后自动：打开专家模式、`RecordEngine.start`、开始键盘监听、开始鼠标监听、预览左下已有 REC 状态应能显示正在录。用户结束演示再点同一位置变成「结束演示」。

为什么技能先留着、先测再决定删不删。`AgentSkillLibrary.all` 里大部分 `ported: true`，`execute` 对 `auto_login` / `volleyball` / `rewards` / `furniture` / `fishing` / `dodge` / `auto_scroll` / `touch` / `drive_dataset` / `preset_afk` / `piano` / `tomato_juice` / `coffee` / `coffee_lite` / `bagel_spam` 有真实分支。`pinkpaw` 是 `warn: true`。`rhythm`、`preset_realtime` 是未移植，会掉进 `performSnapshotStub`。这份文档没有在真机《异环》里把每个循环跑通，所以实现者必须自己测：能跑的继续给 GenericAgent 当工具，跑不通的不要假装能跑，不要为了「架构完整」重写一套平行技能。

---

怎么做。按软件真正跑起来的顺序写。每一步都写到另一个模型不用猜。

先把 GenericAgent vendor 进仓库，例如 `Vendor/GenericAgent/`，保留 MIT 声明。不要在运行时 git clone。用项目的 Python 解释器能 `python ga.py` 或上游等价入口启动。给它加三个面向本项目的工具，名字可以改但职责不能改：`run_aurora_skill`（参数是技能 id，转发到 Swift 的 `AgentSkillCenter.runSkill`，source 固定 `.ai`）；`request_takeover`（告诉 Swift 弹出预览顶上的大按钮，并带上卡住原因文本）；`learn_from_recording`（演示结束后由 Swift 调 Python，或 Python 读 Swift 写好的宫格图和事件文件，调 **Agnes** 看宫格，写出 `memory/<任务名>_sop.md`。Agnes 没配时不要硬调，回报管理员去提醒用户）。Swift 和 Python 之间用本机 HTTP 或 Unix socket，只绑 loopback。建议 Swift 在启动 AI 时开一个只监听 `127.0.0.1` 的小服务，路径至少包括：`POST /skill/run`、`POST /skill/stop`、`GET /skill/status`、`POST /takeover/show`、`POST /takeover/hide`、`GET /snapshot`（返回最近一帧 PNG 路径或直接返回图）。Python 工具只打这个服务，不许自己再注入一套 CGEvent（避免和 `ControlEngine` / `MouseController` 抢键）。GenericAgent 自带的 `macljqCtrl.py` 可以留作逃生舱，默认关掉，本项目以 Swift 注入为准，因为游戏侧已经按 HID 系统状态调过。

技能执行改走 Maa，不要继续手搓。这是这一轮定下来的最大改动。理由：项目现在 18 个技能全是手搓的 `execute` 分支，实测一个都不能用。MaaNTE（`1bananachicken/MaaNTE`）用 MaaFramework 实现的同一批功能**覆盖了现有全部 18 项，并且多出 12 项**（取钱、拍卖王、喷泉签到、女巫占卜、实时战斗辅助、在线地图导航、同步角色能力、俄罗斯方块、本地路线记忆、移动测试、每日全做完、每日快速做完）。MaaNTE 已经在仓库里（`MaaNTE/`），任务清单在 `MaaNTE/assets/resource/tasks/`，共 25 个任务 + 4 个预设。

MaaFramework 官方提供 macOS 原生支持，不是社区魔改：最新版 v5.13.1 有 `MAA-macos-aarch64-*.zip`（原生 Apple Silicon）；PR #1116 已合并，实现了基于 ScreenCaptureKit 的截图、GlobalEventInput 输入、窗口枚举；官方文档 `2.4-控制方式说明` 有独立的 MacOS 章节，要求 macOS 14.0+ 与录屏 / 辅助功能权限。许可证 LGPL-3.0。

**AI 可以直接调用 Maa，这是它的设计用法。** 三级 API：`MaaTaskerPostTask(entry, override)` 跑整套任务（`entry` 就是任务名）；`MaaTaskerPostRecognition` / `MaaTaskerPostAction` 只做识别或只做动作；`MaaControllerPostClick(x, y)` 直接注入一次点击。配套 `MaaTaskerStatus` / `MaaTaskerWait` / `MaaTaskerGetTaskDetail` / `MaaTaskerPostStop` 查状态、等结果、拿每步详情、中断。有 Python binding，GenericAgent 可以直接 import，不必写 HTTP 桥。

**注入后端要能双备份、自动切换。** 用 `MaaCustomControllerCreate(controller, controller_arg)` 写一个 HybridController，注册成 Maa 的控制器：Maa 以为自己只有一个控制器，实际上里面是两个后端——Maa 原生注入 + 自研 `ControlEngine` / `MouseController`。一个炸了自动切另一个。**HybridController 写在 Swift 里**（MaaFramework 有 C API，Swift 可桥接），因为 `ControlEngine` / `MouseController` / `CaptureEngine` 都在那边，两边平级。**不切回**：切走就待在外面，直到下次重启，不要来回抖。官方自己的 `MaaRecordControllerCreate(inner, path)` 就是「包着另一个控制器干活」，说明包装式控制器是框架本来的设计模式，不是 hack。

判定「炸了」分三层：回调返回失败 → 立刻切；Maa 的识别步骤连续失败 → 疑似注入无效 → 切；都判不出来时，用 Agnes 的 10 秒看屏当最终裁判（注入了但游戏没动，这是静默失败，只有整屏语义能看出来）。**自动驾驶那条线不并入 Maa**：MaaNTE 的 `AutonomousDrivingDataset` 只负责录（录 N 秒到目录），不含模型；`InferenceEngine` + `m9_mono` / `game_assist_control` 那套推理是自研资产，用你自己的数据和 checkpoint，Maa 永远做不了。

**MaaNTE 的模板图必须重截。** 它的 `template/*.png` 是 Windows 渲染下截的，`roi` 是 Windows 窗口分辨率下的坐标，窗口匹配用 `UnrealWindow` 这个 Windows 窗口类名。在 macOS 上这些全部要重截、重标。任务清单和流程逻辑能直接借，**图像资源等于从零做一遍**——这是移植里真正的成本，写代码的人不要以为改一行控制器配置就完了。

「我来演示一次」和接管录制的产物，现在有一条更省的路：Maa 原生就能把操作流录成 JSONL（`MaaRecordControllerCreate` / `MaaReplayControllerCreate`），重放也是官方支持的。实现时先看这条够不够，不够再用自己扩 `events.csv` 的方案，不要一上来就重复造。

配置怎么进进程。小本本里要能记下**两个模型**，用途不能混。**主模型**：规划用（想下一步干什么），必须多模态（测看图要过）。**Agnes**：监视用（每 10 秒看一次屏）+ 事后分析用（演示宫格 → 总结成技能），也必须能看图；Agnes 同时是备用模型。先判断有没有**已经用户确认过的主模型**。没有、空文件、或最近一次主模型请求是 401/403/额度耗尽：侧边栏进入管理员模式，不要启动 GenericAgent。Agnes 那一侧没配或挂了：看屏和事后分析都做不了，管理员必须提醒，不要等点完结束演示才爆。管理员是本地写死的系统提示词 + Pollinations 文本模型（无 Key）。系统提示词必须手把手带注册，不能只说「请配置 API」，更不能说「你自己去找个视觉模型」，也不能把 Agnes 说成「系统已经内置的默认密钥」。**系统提示词里必须带上对 Agnes 的主动推荐**，理由讲人话：便宜、能看图、实测验证过。**推荐这件事只发生在管理员嘴里**——界面文案、README、授权文件、任何面向用户的正式文档里都不许出现厂商推荐，App 也不替任何一家背书。

**没配好的时候要疯狂推，不要克制。** 只要还没配好（缺主模型、缺 Agnes、或测不通），管理员的**每一轮回复都必须带上 Agnes 的推荐**——基本每句话都要捎一个。用户问别的、闲聊、抱怨、说「等一下」「我考虑考虑」，推荐照带不误。提一次就以为尽到义务是不合格的。唯一的要求是：**用户问的那件事也得答**，不能因为顾着推就把人晾着。配好之后立刻停，一个字都不要再念，别变成甩不掉的推销员。

至少要覆盖这些话轮，一次只问一步：

1. 说明要接**两个模型**：一个主模型管规划，一个 Agnes 管监视和事后分析。Agnes 是备用模型；用户想拿 Agnes 当主模型，是用户主动提，管理员才带去做。
2. **主动推荐 Agnes，而且没配好之前要一轮不落地推。** 理由用大白话说：便宜、能看图、这边实测过。给官网链接，说明点哪里登录、哪里生成 Key、Key 大概长什么样（`sk-` 开头）。必须补一句「你也完全可以选别家，只要那个模型能看图就行，我不替谁担保」。强调这是用户自己的钥匙、自己注册的账号，App 里没有写死的 Key。**只要还没配好，这句推荐每轮都要带**，用户岔开话题也带回来；但用户问的事照样要答。配好之后不再提。用户卡住就继续在对话里讲下一步，不许把人推出去「你自己研究」。
3. 让用户把密钥发给管理员。对话里贴过来就算交给管理员。管理员收下后先掩码回显（只露头尾），不要把完整 Key 再打进以后的日志。
4. **必须向用户确认模型和用途**：用大白话问「这把是拿来做主模型（规划）的，还是 Agnes 那一侧（监视 + 事后分析）的，还是两件事都用这把？」用户明确说对，才进入测试。用户说「我要用 Agnes 当主模型」，管理员复述确认后再改用途、再测。用户说不对、说是别家、或者说不知道模型名：管理员继续问、继续带，**不许未确认就写入小本本，不许未确认就拿 Agnes 当默认密钥去打真实请求**。
5. **密钥能不能连通、能不能看图，管理员自己测，用户不用自己测。** 用户确认之后先发一条不含图的最小 `chat/completions`（现有 `callLLM` 拼 `/v1` 的规则可以复用，不带 tools、不带游戏图）。2xx 且能解析出助手文本 → 文本连通。两个模型还必须再发一条带小图的请求（一张很小的测试图就行，不要宫格）：模型能针对图片说出不是「我看不到图」的内容，才算多模态过关。纯文本通、看图失败 → 不能当主模型，也不能当监视/事后分析，管理员说清楚，继续带用户换一把能看图的。401/403 → 密钥无效；超时 / 连不上 → 联不上；模型名报错 → 回到第 4 步。侧边栏用人话写结果。成功后才写入项目根 `.llm-key-notebook.md`，写明用途字段（主模型 / Agnes 监视 / Agnes 事后分析）。管理员说「配好了」然后自己退下。失败不写文件，或只在用户明确要求「先存着」时才存未测通的值，默认不存。不要换一家没经过用户点头的服务商硬试。

超时和 max tokens 用代码默认值，正常人永远不用填。写入时权限 `0600`。启动 GenericAgent 时用环境变量把**主模型**打进去做规划；**每 10 秒监视和宫格学习都用 Agnes**（用户另配了别家也行，但用途字段必须写清楚）。禁止再走 Keychain。Pollinations 只留给管理员；所有带图请求必须走用户确认过且看图测试通过的模型。配好之后管理员退出；主模型被删或连续认证失败，管理员再自动顶上。Agnes 挂了，管理员提醒，不要假装还在监视、也不要假装演示已经学会。

用户随时可以主动召唤管理员。输入框里输入 `/`（只打这一个字符就够）必须弹出命令列表，不要等回车才反应。命令很多种，列表**最顶上第一条是「召唤管理员」**，选中即进入管理员模式。也可以整词输入 `/管理员` 回车，效果相同。命令解析发生在 `sendUserMessage` 最前面，比「停止」、比技能关键词、比 GenericAgent 都更早。未实现的其他 `/` 命令至少先占位列出，避免空列表；第一条召唤管理员必须能用。高级设置仍然可以手填 endpoint / 模型，但那是已经会配的人用的后门，不是管理员该指路的方向。

用户在侧边栏输入任务，例如「帮我钓鱼」。若输入以 `/` 开头或正在弹出命令面板，先走命令，不要当任务。若仍在管理员模式（没 Key 自动顶上的，或刚被 `/管理员` 召唤的），这句话先当配置对话处理，不要拿去开钓鱼。已经配好模型、且当前不是管理员模式时，Swift 不要再走 `AgentLoop.shared.handle`。把这句话交给 GenericAgent。GenericAgent 先读 `memory/`：如果已有对应 SOP，按 SOP 调 `run_aurora_skill` 或按 SOP 里记下的精确事件重放。如果没有 SOP，再在已移植且实测能用的技能里选。一次只调一个技能，等 Swift 返回成功/失败摘要。Swift 执行期间，独立的监视时钟每 10 秒从 `CaptureEngine.onFrame` 取最新 `NSImage`，缩到合适大小（不要用 120 帧宫格），发给 **Agnes**，prompt 必须带上用户原任务、当前技能 id、最近一次技能回报。返回要能解析出：是否跑偏、是否该接管、一句话原因。跑偏则 `request_takeover`。模型自己调用 `request_takeover` 同样弹出按钮。失败计数底线同时生效：同一技能连续验证失败 3 次，或本任务步数超过 20，即使模型嘴硬也要弹。20 这个数字可以后来调，但不能删掉底线。弹的时候预览最顶上出现横条，中间巨大「接管」，横条上用小字写卡住原因。用户也可以不等人家卡住，点「我来演示一次」。

用户点接管或点我来演示一次之后，同一套录制启动，不要两条实现。自动打开专家模式（现有把按住时长换成 steer/throttle/brake 的那条路径继续写 `controls.csv`，驾驶类演示还用得着）。调用现有 `RecordEngine.start(perspective:)`，目录仍然是 `AuroraPaths.dataDir()/raw_clips/clip_<yyyyMMdd_HHmmss>/`，帧仍然是 `frames/00000.jpg` 起的 640×360 JPEG。`KeyboardMonitor.start()`。另外加全局鼠标监听：`NSEvent.addGlobalMonitorForEvents` 听 leftMouseDown（以及需要的话 rightMouseDown / scrollWheel），记下时间戳和位置。坐标要同时记下屏幕点坐标和换算到游戏截图像素的位置，换算规则跟 `MouseController` 注释一致：CGEvent 是左上原点的点，截图像素大约是点乘 backingScaleFactor，以主屏为准；SOP 里重放必须走 `MouseController.click(at:)` 用的那套点坐标，不要把像素直接当点。事件写到 clip 目录里新文件，建议叫 `events.csv`，不要破坏旧 `controls.csv` 表头，训练端还在扫那个格式。`events.csv` 建议列：`t_sec,kind,key_code,button,x_pt,y_pt,x_px,y_px,click_count,scroll_delta`。`kind` 至少覆盖 `keydown` `keyup` `click` `scroll`。录制中预览顶上的大按钮变成「结束演示」。`RecordEngine` 的 `maxClipsPerKind = 10` 继续有效，不要为了演示关掉清理。

用户点结束演示。`RecordEngine.stop()`，停键盘和鼠标监听。不要在主线程做宫格。后台读 `frames/`。`RecordEngine.targetFps` 是 24，宫格不要 24fps 全上。抽到大约 2Hz，上限 120 帧（60 秒）。更长的演示按 120 帧一批切，每批一张宫格、一次视觉请求，再把各批 JSON 汇总成一份 SOP；不要把几百帧塞进一张没实测过的大图。每格标签黑底白字，格式 `F{n} t={秒}s`，已验证过大约 150×150 格加 20px 标签条。拼好的 PNG 放在同一 clip 目录，例如 `contact_sheet.png`。视觉请求超时至少 90 秒（45 秒曾经不够）。把宫格、任务名、卡住原因、`events.csv` 的摘要（不要把几万行原始 CSV 整份糊进 prompt，按时间排序后做成「t=3.51s click (812,430)」这种压缩列表）一起发给 **Agnes**。Agnes 没配或看图测试没过：不要发，管理员提醒用户去配；不许拿 Pollinations 看宫格。事后分析只许输出语义 JSON：关键帧编号、每帧在干什么、流程摘要、最小复现步骤。实现者用 `F8` 这种编号对齐抽帧时间，再在 `events.csv` 里取该时刻附近的真实点击和按键。生成的 SOP 必须是人能读、模型能再执行的 Markdown，至少包括：前置条件、步骤列表（每步有语义描述 + 来自 CSV 的坐标或键码 + 大约时间）、怎么验证成功。写入 GenericAgent 的 `memory/<任务名>_sop.md`。文件名用任务的稳定短名，不要用整句用户原话。写完后侧边栏告诉用户已经学会，下次直接走 SOP。

下次同一任务。GenericAgent 读到 SOP 就按步骤重放：技能型步骤继续 `run_aurora_skill`；点击型步骤调 Swift 暴露的点击/按键接口（可以是 `/input/click` `/input/key`，内部还是 `MouseController` / `ControlEngine`）。重放时仍然每 10 秒监视。监视说跑偏，再次请求接管，新演示覆盖或追加 SOP，不要无限叠十份互相打架的文件。

现有技能怎么交给大脑。技能执行改走 Maa 之后，给 GenericAgent 的工具清单应该以 **MaaNTE 的任务名**为主（`ClaimRewards`、`Fish`、`MakeCoffee`……），而不是现在这套手搓 id。Swift 的 `AgentSkillCenter` 保留，但降级为自研兜底：Maa 那条路整个挂了、或某个技能 Maa 侧还没在 macOS 校准好，才回落到它。回落必须显式写在日志和侧边栏里，不许静默。`pinkpaw` 带 warn，不要默认让模型自己点。`drive_dataset` 是采集不是玩游戏，除非用户明确说采集，否则不要当通用动作。`preset_afk` 是串多个技能的预设，大脑自己能串的话不必优先调它。

监视、规划、宫格三种视觉请求必须分开函数，不要共用一个「随便发张图」的入口。**监视**：走 Agnes，单帧、短 prompt、短 max tokens、10 秒节流，失败就跳过这一拍，不许重试打爆 RPM。**规划**：走主模型，默认可不带图。**宫格**：走 Agnes，只在演示结束，长超时，一次一张（或分批）。任何路径都不许把视频文件扔给视觉模型（Agnes 自己说过不支持视频）。不许用 Pollinations 看任何图。

侧边栏要能看到推理过程。现有 `appendSystem` 继续用。至少打出：当前用的视觉端点（不要打出完整 Key）、每 10 秒监视的一句话结论、技能启动停止、接管弹出原因、宫格请求耗时、SOP 写到哪个文件。不要做假进度。

权限。键盘监听、键鼠注入、屏幕采集都要辅助功能 / 屏幕录制。预览里已有权限提示，不要另做一套互相矛盾的文案。管理员密码这类信息不写进 SOP，也不写进仓库。

不要做的事，再列一遍防止下一个模型手痒。不要恢复 `VisionAPIConfig.swift` 那种还没问完就提交的配置类。不要把第一次打开做成开发者网关面板（Base URL、模型、超时、max tokens 平铺）。不要把 Agnes 写成内置默认密钥。**不要把厂商推荐写进界面文案、README、授权文件或任何面向用户的正式文档**——推荐只从管理员嘴里说出来。不要让用户自己去网上找模型。不要未确认就把任何模型写进小本本。不要让纯文本密钥当主模型或监视/事后分析。**不要把监视和规划混成一个模型**：监视每 10 秒走 Agnes，规划走主模型。不要让用户自己去 curl 测密钥，连通和看图测试是管理员的活。Agnes 没配时不要假装还在监视，也不要假装演示已经学会，管理员必须提醒。不要把管理员做成游戏攻略机器人。不要把 Key 写进源码。不要用 Pollinations 看图。不要在没配模型时启动看屏。不要把以 `/` 开头的输入丢给 GenericAgent。不要把「召唤管理员」做成藏在菜单深处的项，它必须是 `/` 列表最顶上第一条。不要逐帧调用视觉。不要重新发明 `RecordEngine`。不要绕开 `runSkill` 在 Python 里直接乱按。不要把 SOP 存到 Application Support 却让 GenericAgent 去 `memory/` 找。不要扩大到《异环》以外的游戏。不要把「代码能编译」写成「技能已验证」。

给实现者的硬接口，防止读散文读丢。

`AgentSkillCenter.shared.runSkill(_ id: String, source: AgentInvokeSource)`，AI 侧 source 用 `.ai`。`stopSkill` 同样。技能 id 以 `AgentSkillLibrary.all` 为准。**这套现在是兜底层**，主力执行是 Maa 的任务（见上面「技能执行改走 Maa」）。

Maa 集成：MaaFramework C API 走 Swift 桥接。要用的接口就这几个——`MaaTaskerCreate` / `MaaResourcePostBundle` / `MaaMacOSControllerCreate` / `MaaCustomControllerCreate`（挂 HybridController）/ `MaaTaskerPostTask` / `MaaTaskerStatus` / `MaaTaskerWait` / `MaaTaskerGetTaskDetail` / `MaaTaskerPostStop`。MaaNTE 资源包路径 `MaaNTE/assets/resource/`，任务清单 `MaaNTE/assets/resource/tasks/`，任务定义 `MaaNTE/assets/interface.json`。macOS 控制器要 macOS 14.0+，权限是录屏 + 辅助功能，跟现有预览里的权限提示是同一套，不要另写文案。Maa 的二进制要么 vendor 进 `Vendor/`，要么由构建脚本下载固定版本，**不要依赖运行时 git clone**。

`CaptureEngine.onFrame: ((NSImage, CGImage) -> Void)?` 是监视截图来源。不要另开一套 ScreenCaptureKit。

`RecordEngine.start(perspective:)` / `stop()` / `appendFrame(image:steer:throttle:brake:)` / `sessionURL` / `frameCount`。clip 在 `AuroraPaths.dataDir()` 下 `raw_clips/clip_<时间戳>/`。旧 CSV 表头保持 `t_sec,frame,steer,throttle,brake`。新事件文件并列存放。

`KeyboardMonitor.holdDuration(keyCode:)` 继续给专家模式连续量。按键事件日志要另外记，因为 `holdDuration` 在 keyUp 后就没了。

点击重放走 `MouseController.click(at:)`，传入点坐标。**它同时是 HybridController 的自研那一半**——Maa 注入后端炸了之后，切过来执行的就是这套。

`CaptureEngine.onFrame` 另外还是 Agnes 10 秒监视和接管按钮「炸了」判定的画面来源，一处采集三处用，不要各开各的。

项目根 `.llm-key-notebook.md` 是唯一凭证文件。读它，不要读钥匙串。里面要能区分**主模型**（规划）和 **Agnes**（监视 + 事后分析）。主模型空或认证失败时侧边栏必须切回管理员，不要继续把用户话丢给 GenericAgent。Agnes 空或挂了时管理员必须提醒，不要静默跳过监视和宫格学习。

管理员（与引导员同一角色）：无 Key 可用 Pollinations `https://text.pollinations.ai/openai`、模型 `openai`。系统提示词写死在 App 里。职责是带用户去注册、**主动推荐 Agnes（便宜、能看图、实测过）**、收下密钥、确认「哪家、什么模型、主模型还是 Agnes 那一侧」、测连通、测能不能看图、通了再保存。正常要接**两个模型**：主模型管规划，Agnes 管监视和事后分析。Agnes 同时是备用模型；用户强行要拿 Agnes 当主模型，管理员才带去做。**Agnes 不是内置默认密钥，也不是 App 指定的供应商**——推荐只在管理员对话里发生，界面和文档不写。输入框打 `/` 弹出命令列表，最顶上第一条是「召唤管理员」。

密钥测试（管理员执行）：先最小文本请求确认 Key 本身通；两个模型再带一张小图确认多模态。纯文本通、看图失败 → 拒绝当主模型和监视/事后分析。2xx 且能解析助手文本 → 文本通；看图那次还得模型真的在说图，不能是「我看不到图片」。401/403 → 密钥不行；超时或网络错误 → 联不上；模型相关 4xx → 再确认模型名。结果用人话写进侧边栏。默认两档都过才按用户确认的用途写入小本本。

宫格已验证参数：最多 120 格、约 10×12、格约 150px、标签约 20px、PNG 约 1.4MB、超时 90 秒、一次调用。超出就分批。

Agnes 的 Base URL `https://api.agnes-ai.cn/v1`，聊天路径按 OpenAI 兼容拼 `/chat/completions`（现有 `callLLM` 已经会给 base 补 `/v1`）。模型名以用户确认为准，实测过的是 `agnes-2.5-flash`。**用途是监视（每 10 秒）+ 事后分析（宫格），不是规划。** 这不是安装包里的默认 Key。Pollinations 文本：`https://text.pollinations.ai/openai`，模型字段填 `openai`，不要填 vision，不要看图。

演示理解的视觉输出只当语义。最终 SOP 步骤里的 x/y/key 必须能在 `events.csv` 找到对应行。找不到就在 SOP 里标明「缺事件，不能自动重放」，不许拿视觉模型瞎填的数字顶上。

**这一轮新定的五条，跟旧稿冲突时以这里为准：**

1. **监视和规划是两个模型。** 每 10 秒监视走 Agnes；规划走主模型。不要把两者混成一个。
2. **Agnes 是监视 + 事后分析 + 备用。** 它不是内置默认密钥，也不是规划的默认模型。用户强行要用 Agnes 当主模型，是用户提，管理员才带去做。
3. **推荐 Agnes 这件事，只从管理员嘴里说，而且没配好之前要疯狂推。** 系统提示词里写死要推荐（理由：便宜、能看图、实测过），并且必须补「你也可以选别家，只要支持看图」。**只要用户还没配好，管理员每一轮回复都要带一次这个推荐**，基本每句话都捎一个，提一次就完事是不合格的；用户岔开话题也要带回来，但用户问的事照样得答。配好之后立刻停。界面文案、README、授权文件、面向用户的正式文档里**一个字都不许写厂商推荐**。用户自己去注册账号、自己交钥匙，App 不带任何 Key、不替任何厂商背书。
4. **技能执行改走 Maa。** MaaNTE 覆盖现有全部 18 项技能并多出 12 项；MaaFramework 有官方 macOS arm64 支持；AI 通过 `MaaTaskerPostTask` 等三级 API 直接调用。但 MaaNTE 的模板图是 Windows 的，macOS 上必须重截。
5. **注入双备份、不切回。** HybridController 写在 Swift 里，内部两个后端（Maa 原生 + 自研 CGEvent），一个炸了自动切另一个，切走就待在外面直到下次重启。自动驾驶那条线（`InferenceEngine` + 自己的 checkpoint 和数据）不并入 Maa。

写完代码之前先对着这份文件看一遍有没有重新引入：钥匙串、共享 Key 池、逐帧视觉、不带事件流的宫格学习、把 Pollinations 当眼睛、把 Agnes 写成内置默认密钥、**把监视和规划混成一个模型**（监视 10 秒走 Agnes，规划走主模型）、把接管按钮做进侧边栏却不放预览顶上、第一次打开就甩开发者网关表单、没模型时不出现管理员、让用户自己去找模型、未确认就写入默认模型、让用户自己测密钥连通、`/` 列表里召唤管理员不在最顶上、**继续手搓已经能用 Maa 跑的技能**、**把 MaaNTE 的 Windows 模板图当成 macOS 能直接用**、**把 HybridController 写成单后端**（那就丢了兜底）、**让 HybridController 自动切回**（已定：不切回）。出现任何一条，就是没按这份文件做。
