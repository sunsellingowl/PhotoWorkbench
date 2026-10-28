# 开发与验证

PhotoWorkbench 是日常图片工具。用户说明在根目录 README；本文件保留构建、安全约定和验证边界。

## 构建

需要 Apple Silicon Mac、macOS 15 或更新版本、完整 Xcode 与 Python 3。当前只为 arm64 构建。固定的预编译引擎默认从 `/Applications/ImageOptim.app` **1.9.3** 复制，不会修改原应用；其他位置可通过 `IMAGEOPTIM_APP` 指定。引擎摘要必须与锁文件一致，不能直接用最新版替代。

```bash
bash run_build.sh
open dist/PhotoWorkbench.app
```

`run_build.sh` 自动调用 `scripts/run_prepare.sh`：首次下载 ImageOptim、libpng 固定源码和 PNGOUT 官方归档，应用补丁，复制引擎与许可证，并校验 SHA-256；依赖已准备好时只做本地校验。首次准备需要网络及指定版本的 ImageOptim，后续构建无需联网。Python 使用 `python3`，也可设置 `PYTHON=/path/to/python`。

构建输出为 `dist/PhotoWorkbench.app`，日志为 `build/build.log`。成品含引擎及 Notices，不需要运行时 Python、Rust 或额外的 ImageOptim。签名仅为本机临时签名，不包含 Developer ID 或 Apple 公证，也不构成公开二进制发行许可核验。

也可在准备依赖后用 Xcode 打开 `PhotoWorkbench.xcodeproj`：

```bash
bash scripts/run_prepare.sh
open PhotoWorkbench.xcodeproj
```

添加原生源文件后运行 `python3 scripts/generate_project.py`，提交生成的工程文件。资源打包阶段显式声明引擎、Notices 和图标输出，确保增量构建更新资源后重新签名。图标源为 `scripts/make_icon.swift`，生成的 `native/AppIcon.icns` 是构建资源，随源码保留。

## 检查

安装 Pillow 到所选 Python 环境，然后运行：

```bash
python3 -m pip install Pillow
bash run_checks.sh
```

检查会构建应用、生成图片并运行原生验收。只使用生成图片，不访问个人图库；验证保存时会将生成图片的原件移入系统废纸篓。已有同一源码的构建时可用 `bash run_checks.sh --skip-build`。Clang 和 Swift 模块缓存默认保存在 `build/ModuleCache/`。原生验收覆盖创建时间命名、冲突与撤销、透明 RGB、16 位 PNG、EXIF/ICC 保留、各引擎、可选有损、损坏及只读文件、保存/引擎失败、备份丢失、外部改动、取消和 300 张图片批次。

0.9 首次验收在本机 macOS 27 / Xcode 27.1 上通过 117 项原生检查（含上游对比）及签名检查。当前精简套件移除了其中一项上游输出比较，其余 **116 项安全回归检查通过**。初始上游对比工具在 `v0.9` 标签和本机忽略的 `legacy/validation/` 中保留，当前检查不再编译或运行它，也不生成对比报告。此前的独立 GUI 验证确认设置切换、窗口尺寸、创建时间预览和 Quick Look。上述结果不代表 Intel、所有旧系统、网络盘或云同步竞争场景均已通过实机验证。

## 文件职责与 Git 范围

| 路径 | 职责 | 保留原因 |
| --- | --- | --- |
| `native/` | SwiftUI、重命名、后端桥接、校验与安全保存 | 应用源码和资源 |
| `PhotoWorkbench.xcodeproj/` | 生成的共享工程 | 支持 Xcode 直接构建 |
| `run_build.sh`、`run_checks.sh` | 构建与验收入口 | 根目录仅保留两个常用命令 |
| `scripts/run_prepare.sh`、`scripts/prepare.py` | 固定依赖准备与校验 | 首次构建及后续校验必需 |
| `scripts/bundle_resources.sh` | 打包引擎、图标和 Notices | Xcode 构建阶段调用 |
| `scripts/generate_project.py`、`scripts/make_icon.swift` | 工程与图标维护 | 保留可编辑来源 |
| `tests/` | 验收、故障注入、测试图片生成 | 防止文件安全行为回归 |
| `patches/`、`dependencies.lock.json` | 上游差异及版本/摘要 | 保证依赖可复现、改动可审阅 |
| `licenses/`、`THIRD_PARTY.md` | 第三方许可与来源 | 保留原作者声明及打包所需 Notices |
| `LICENSE`、`COPYRIGHT` | GPL-2.0-or-later 全文与项目授权声明 | 明确自有代码的使用及分发条件 |

Git 不纳入 `vendor/`、`build/`、`dist/`、个人编辑器配置或本地 `legacy/`。这些目录中的下载、引擎副本、日志、测试结果和编译缓存不是项目自有源码。源代码不按运行时是否调用来筛选：构建工具、测试和许可证也是维护一个可复现开源项目所需的内容。

旧 Python/Tkinter 工具保留在本机忽略的 `legacy/`，仍可运行 `bash legacy/run_app.sh` 和 `bash legacy/run_checks.sh`；原始文件也在 `v0.9` 标签中。旧版保留分钟精度和原时间优先级，不具备原生压缩、秒级命名或撤销功能。历史提交不重写。

## 安全约定与限制

- 原生版仅使用文件创建时间和本机时区。添加时缓存命名依据；自己的压缩和恢复后同步路径及签名，不接受未经核验的外部改动。
- 改名前预计算目标，执行独占移动。重入、权限、外部修改及撤销冲突必须检查，不覆盖图片、废纸篓条目或恢复文件。
- PNG 以 libpng 解码为不预乘、不做色彩转换的 RGBA16，比较全部像素（含完全透明区域 RGB）；JPEG 使用同一路径的 ImageIO 解码和固定目标色彩空间比较。
- 保留元数据时比较 PNG 附加块和 JPEG APP/COM 数据。不能证明保留完整的候选被拒绝，不能仅因结果更小就保存。
- 同卷临时文件与原子交换用于保存；保留原件，废纸篓失败则回退，无法安全回退时给出恢复文件路径。Stop 仅取消剩余任务。
- Restore Originals 保留当前文件名，恢复成功后保留原废纸篓条目。退出清空列表与会话撤销历史，保留设置和窗口大小。
- 默认严格无损、优化力度 4、保留元数据/日期/权限。Guetzli 需要显式有损、JPEG 质量至少 85 及移除 JPEG 元数据，冲突时不自动修改设置。
- APNG 不压缩；单张解码缓冲超过 256 MiB 时拒绝压缩；非常规 JPEG 或无法完整验证的元数据会保守跳过。每次最多处理两张图片，像素校验串行。
- 不启用跨会话结果缓存，不读取 ImageOptim 的共享设置或迁移旧缓存。上游源码有修改时必须同步补丁和锁定摘要，不直接升级引擎。

## 发布边界

GitHub 源码仓库与可下载的应用发行附件是两件事。目前未上传应用发行附件。发布捆绑二进制前，需要逐一核对引擎再分发许可，并准备 GPL 组件的对应源码及构建资料。单靠本仓库的下载地址、摘要或“尊重版权”声明不能代替这些工作。PNGOUT 不属于 GPL，ImageOptim 自己取得的捆绑许可不自动授权本项目。
