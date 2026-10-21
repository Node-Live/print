# 给在这个仓库工作的代理

NODE Print 是 NODE 的桌面打印客户端，Windows 与 macOS 各一套原生代码，共享的只有 `docs/protocol.md`（网页依赖的本机 HTTP 契约）和 `docs/zpl.md`（斑马打印机的 ZPL 路径）。改契约先找 main 裁决，再同步两端。

## 代码
- 按各自平台的习惯写：Windows 用 C# 的惯例与 WinUI 的写法，macOS 用 Swift 与 SwiftUI 的写法；不为了"两端像"而放弃平台惯例。
- 注释尽可能少，只写代码说不出的东西；注释、提交、配置里不写任何决策号、需求号、代理名、日期或历史叙述。
- 不留兼容分支、不为"以后可能"加抽象或配置项；只实现 `docs/` 里写明的行为。
- 用户可见文案源文本是英文，另有 zh-CN 与 es-ES 两种翻译，跟随系统语言，其余语言回落英文。文案里不出现 "DROPP"，3PL 一律叫 "warehouse"。
- 代码里不用 "NODE Print" 之外的产品名；版本号只在一处定义，窗口顶部显示的就是它。

## 测试
- 每条业务规则一条用例（正常路径 + 该规则的拒绝路径），不写压力、循环、长等待类用例；不为测试拆方法。
- `testdata/zpl/*.json` 是两端共用的向量，两端都必须逐字节通过。
- 开发中只跑自己改到的测试目标；CI 上的完整构建按分支推送触发，一次推送尽量带一批改动，不要一行一推（私有仓库的 Windows 分钟按 2 倍、macOS 按 10 倍计费）。

## 提交与分支
- 英文 Conventional Commits（`feat(windows): …`、`fix(macos): …`、`docs: …`），每完成一小步就提交。
- 只推自己的分支（`feat/windows`、`feat/macos`）；`main` 只由 main 合并。
- 推 `v<版本>` 标签就是发版（`.github/workflows/release.yml`），只由 main 做；见 `README.md` 的 Releases。
- 不在 worktree 里用 `git stash`；不用 `pkill -f`。
