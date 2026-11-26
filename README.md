# 反重力指挥 Codex 工作（Antigravity Codex Commander）

> 一套专为 **Google Antigravity** 主控 + 本地 **OpenAI Codex CLI** 打造的轻量零依赖 Skill（Windows / PowerShell 7 原生打磨）：把**主控监控 Token 省掉 86%–95%**、**Codex 单步非缓存输入降 41%**、**高清大图塞入清零**，同时保持编码与长任务推理质量不打折。

English summary: A lightweight, zero-dependency Antigravity skill + PowerShell wrapper suite for delegating long-running coding, debugging, and code review tasks to local **OpenAI Codex CLI**, featuring a **zero-token speech-only log watcher**, **quality-first 3-trigger automatic window shifting**, **auto-injected Codex output & image-inspection discipline**, and **frontend ownership boundaries**.

---

## 核心特性（为什么做这套 Skill）

**做这套 Skill 的初衷很直接**：GPT / Codex 的编码与推理能力很强，但直接交互时防御性太强、表达生硬晦涩、可读性极差；这套 Skill 就是**用 Gemini（Antigravity）当「翻译官 + 指挥官」去翻译需求、指挥 GPT 干活，再把它的关键回复与结果转述回人话**。围绕这一协作模式，以下 6 项机制把双方的 Token 消耗与长任务稳定性也一并打磨到位：

1. **零 Token 本地静默只传话 Watcher（`wait-codex-update.ps1`）**
   - 彻底告别定时轮询（如每 15–20 秒查一次进度）和刷屏式“实时播报”。
   - 本地脚本后台静默监听日志（**0 LLM Token 消耗**），**硬锁定 `speech-only-locked` 模式**：自动过滤 `[思考]`、`[执行命令]`、`[命令完成]`、`[修改文件]` 等过程噪声，只在 Codex 真正开口（`[Codex说]`）、报错（`[ERROR]`/`[STDERR]`）、结束（`[END]`）或连续静默 10 分钟心跳时才唤醒主控。
2. **质量优先的三触发自动换窗体检（`check-session-health.ps1`）**
   - 零 Token 直接扫描本地 `~/.codex/sessions/**/*.jsonl` rollout 记录，统计压缩次数、当前上下文大小与空闲时长。
   - **硬前提**：绝不中途打断未完成的单轮任务，始终先完成并验收当前回合，再趁 Prompt Cache 还热时自动交接换窗：
     - **触发线 1（压缩硬换班）**：累计压缩 `>= 4` 次，老窗口趁热写交接单，开全新 `exec` 窗口。
     - **触发线 2（大阶段切换）**：上下文 `>= 150K`（或已压缩 `>= 1` 次）且命中大阶段切换信号（明确跨 Phase / 核心 KPI 切换 / 代码区切换 / 放弃旧路线），老窗口趁热交接。
     - **触发线 3（隔夜/冷缓存重续）**：空闲 `>= 10` 分钟且上下文 `> 150K`——上一阶段已结项则由主控直接根据产物与 `git diff` 写交接单开新窗（避免白白冷启重算 150K–250K）；半途中断则默认保留 `resume` 记忆（仅在 `> 200K` 或压缩 `>= 3` 次时换窗）。
3. **派单自动注入输出与审图纪律（`run-codex.ps1`）**
   - 每次 `exec` / `resume` 派单自动在末尾注入 `[Codex 输出与审图纪律]`：禁止把大日志/整份大文件/宽泛 `grep` 原样倒进 stdout，优先精准行号与短脚本聚合。
   - **2K / 高清审图默认由 Antigravity 自己完成**，避免把几 MB 的原图塞进 Codex 的长会话历史。
4. **模型与思考等级防跑偏锁 + 环境变量可配**
   - 默认锁定 `gpt-6.2-sol` + `high` 推理强度，**禁止 AI 代理通过命令行参数临时降级模型**；人类用户可通过环境变量自由切换自己订阅可用的模型与思考等级。
5. **可选配套规则：前端归属与先对齐视觉（`rules/frontend-ownership.md`）**
   - 默认不把前端页面/UI 交给 Codex，由 Antigravity 自己先和用户对齐视觉风格、配色、布局细节后再实现（用户明确指定除外）。
6. **Windows 原生踩坑全打通**
   - 解决 Windows 下 `codex exec` stdin 管道挂死、UTF-8 无 BOM 中文乱码、`codex.exe` 多安装路径自动发现（`PATH` → `~/.codex/config.toml` → `%LOCALAPPDATA%\OpenAI\Codex\bin` → `AppxPackage`）、PowerShell `StrictMode` 数组边界与并发日志读写共享锁。

---

## 真实 4 天重度开发实测数据（优化前 vs 优化后）

在真实复杂项目上连续高强度跑了 4 天（**7 个 Antigravity 主控会话** + **30 个 Antigravity 派出的 Codex 会话**，累计 **3,010 次 Codex 模型调用**，是优化前单会话基线的 **5.1 倍**工作量）：

### 1. Antigravity（主控侧）

| 指标 | 优化前（轮询 + 实时播报） | 优化后（零 Token 静默只传话） |
| :--- | :--- | :--- |
| 监控唤醒频率 | 46 分钟 144 次（`3.11 次/分钟`） | 每轮 30–90 分钟长任务仅唤醒 **~5 次** |
| 主控监控 Token 消耗 | `108.6 万 tok/分钟` | **↓ 86.4% – 95.7%** |
| 定时轮询 `schedule` | 频繁触发 | **`0` 次** |
| 2K 高清截图视觉验收 | 混在 Codex 历史里 | Antigravity 自行审图 **`287` 张** |

### 2. Codex（执行侧）

| 指标 | 优化前单会话基线（`587` 次调用） | 优化后 30 会话实测（`3,010` 次调用） | 效果 |
| :--- | :--- | :--- | :--- |
| **压缩次数** | 单会话 **6 次** | 30 会话合计 **5 次**（单会话最高 1 次，25/30 为 0 压缩） | 彻底消灭滚雪球超长窗 |
| **`≥ 150K` 输入占比** | `75.7%` | **`57.0%`** | **↓ 18.7 pct** |
| **`≥ 200K` 调用占比** | `34.1%` | **`15.9%`** | **直接腰斩** |
| **单次调用平均输入** | `163.7 K` | **`134.6 K`** | **↓ 17.8%** |
| **单次调用非缓存输入** | `3,986 tok/次`（缓存 `97.6%`） | **`2,347 tok/次`**（缓存 **`98.3%`**） | **↓ 41.1%** |
| **工具输出均值 / `>10KB` 占比** | `~6.6 KB` / `~25%` | **`3.7 KB`** / **`10.0%`** | **输出瘦身 ~44%** |
| **往 Codex 上下文塞大图** | `6` 张（`6.76 MB`） | **`0` 张**（`0 KB`） | **彻底清零** |

---

## 目录结构

```text
.
├── README.md
├── LICENSE
├── install.ps1                                # Windows 一键安装脚本（不触碰 ~/.codex/）
├── skills/
│   └── codex-sol-high/
│       ├── SKILL.md                           # Antigravity 技能主说明书
│       ├── scripts/
│       │   ├── run-codex.ps1                  # Codex CLI 流式包装脚本（锁模型、注纪律、后置体检）
│       │   ├── wait-codex-update.ps1          # 零 Token 静默只传话日志监听脚本
│       │   └── check-session-health.ps1       # 零 Token 本地 rollout 健康体检脚本
│       └── resources/
│           └── handoff-template.md            # 结构化交接单模板（强制记录已失败路径）
└── rules/
    └── frontend-ownership.md                  # 可选配套规则：前端页面归属与开发前视觉对齐
```

---

## 环境要求

- **操作系统**：Windows 10 / 11
- **Shell**：PowerShell 7+（`pwsh`）
- **Codex CLI**：已在本机安装并登录 OpenAI Codex CLI（`codex.exe` 在 `PATH`、~/.codex/config.toml 或 `%LOCALAPPDATA%\OpenAI\Codex\bin` 下均可自动识别）
- **主控端**：Google Antigravity（或任何支持 `SKILL.md` 的 Agent）

---

## 快速安装

### 方式一：运行一键安装脚本（推荐）

```powershell
# 仅安装 Skill 到 %USERPROFILE%\.gemini\config\skills\codex-sol-high
pwsh -NoProfile -File .\install.ps1

# 同时安装可选的「前端归属与先对齐视觉」全局规则到 %USERPROFILE%\.gemini\config\rules\
pwsh -NoProfile -File .\install.ps1 -IncludeFrontendRule
```

*(安装脚本绝不会修改你的 `~/.codex/` 目录或 `config.toml`。)*

### 方式二：手动复制

1. 将 `skills/codex-sol-high/` 整个文件夹复制到 `%USERPROFILE%\.gemini\config\skills\codex-sol-high\`。
2. （可选）将 `rules/frontend-ownership.md` 复制到 `%USERPROFILE%\.gemini\config\rules\frontend-ownership.md`。

---

## 自定义模型与配置（环境变量）

默认配置为 `gpt-6.2-sol` + `high` 推理强度 + `compactions >= 4` 强制换窗。AI 代理**无法**通过命令行参数擅自降级模型，但你本人可以通过环境变量覆盖默认值：

| 环境变量 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `CODEX_SKILL_MODEL` | `gpt-6.2-sol` | 指定锁定的 Codex 模型名称（例如 `gpt-5.4`、`o3` 等你账号支持的模型） |
| `CODEX_SKILL_REASONING_EFFORT` | `high` | 指定推理强度（`low` / `medium` / `high` / `xhigh`） |
| `CODEX_SKILL_COMPACTION_THRESHOLD` | `4` | 触发强制交接换窗的累计压缩次数阈值 |

示例（在系统环境变量或 PowerShell Profile 中设置）：

```powershell
$env:CODEX_SKILL_MODEL = "gpt-6.2-sol"
$env:CODEX_SKILL_REASONING_EFFORT = "high"
$env:CODEX_SKILL_COMPACTION_THRESHOLD = "4"
```

---

## 安全提示

- `run-codex.ps1` 的默认 `-Sandbox` 为 `danger-full-access`（方便在本地开发机上免频繁弹窗完成构建/测试）。如果你希望更保守的默认权限，可在派单时显式传 `-Sandbox workspace-write` 或 `-Sandbox read-only`，或直接修改 `run-codex.ps1` 第 13 行默认值。
- 如果你使用个人 ChatGPT 订阅登录 Codex CLI，请仅在人工交互会话中按需触发，**不要**用于无人值守死循环或高频并发刷任务。

---

## 快速自检（DryRun）

安装完成后，可以在任意目录跑一次零消耗 DryRun 验证路径、模型配置与纪律注入：

```powershell
pwsh -NoProfile -File "$env:USERPROFILE\.gemini\config\skills\codex-sol-high\scripts\run-codex.ps1" `
  -WorkDir "." `
  -Prompt "Health check dry run" `
  -DryRun
```

查看本机最近 5 个 Codex 会话健康状态（零 Token）：

```powershell
pwsh -NoProfile -File "$env:USERPROFILE\.gemini\config\skills\codex-sol-high\scripts\check-session-health.ps1" -Top 5
```

---

## License

[MIT](./LICENSE)
