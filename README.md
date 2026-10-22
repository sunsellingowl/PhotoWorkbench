# Photo Time Renamer

按照片拍摄时间批量重命名的桌面工具。当前可运行版本使用 Python、Tkinter 和 Pillow；下一阶段计划将重命名逻辑移植到 ImageOptim 的 Objective-C 项目，在同一个原生 macOS 应用中完成重命名与压缩。

## 当前状态

- 已实现：选择多个文件夹、递归扫描、按时间重命名、重名编号、日志和统计。
- 已有：启动脚本和使用临时图片的回归检查。
- 环境已验证：Apple Silicon 本机上的 Xcode、Rust/Cargo，以及原生框架的基础编译检查。
- 尚未完成：获取 ImageOptim 源码、完整构建原版、原生重命名模块和界面集成。本仓库目前不包含 ImageOptim 源码或定制应用。

## 当前命名规则

文件名格式为 `YYMMDDHHmm.ext`，使用 24 小时制，精确到分钟，不保留原文件名。例如拍摄于 2026 年 10 月 21 日 14:35 的 `IMG_1234.jpg` 会改为 `2610211435.jpg`。

1. 依次尝试 EXIF 的 `DateTimeOriginal`、`DateTimeDigitized`、`DateTime`；无法读取有效时间时，使用文件修改时间，而不是文件创建时间。
2. EXIF 时间按记录值使用；文件修改时间按电脑本地时区转换。目前不处理 EXIF 时区偏移。
3. 保留原扩展名及其大小写；目标名称已存在时追加 `_001`、`_002` 等编号。
4. 文件名已匹配本次读出的时间及可选编号时跳过；旧的 `originalname_timestamp.ext` 格式会转换为当前格式。
5. 在原文件夹内直接改名，不复制图片、不压缩，也不提供撤销记录。时间信息变化后，再次运行可能重新命名。

扫描扩展名包括 JPG、JPEG、PNG、WebP、HEIC、HEIF。扩展名被扫描不代表元数据一定可读；HEIC/HEIF 等格式取决于 Pillow 和本机解码支持，读取失败时会退回文件修改时间。

## 运行现有 Python 版本

依赖 Python 3.10+、Tkinter 和 Pillow。macOS 启动脚本优先使用本机环境 `/Users/cc/opt/miniconda3/envs/mydailypython`，其次尝试 Miniconda 基础环境和系统路径中的 `python3`。

如果首选环境中尚未安装 Pillow，可执行：

```bash
/Users/cc/opt/miniconda3/envs/mydailypython/bin/python -m pip install Pillow
```

在项目目录启动：

```bash
bash run_app.sh
```

也可以在 Finder 中双击 `RunPhotoTimeRenamer.command`。窗口中添加文件夹，再点击 `Start Rename`；会同时处理子文件夹。

核心 Python 程序也可在满足依赖的 Windows/Linux 环境中运行：

```bash
python photo_time_renamer.py
```

## 检查

```bash
bash run_checks.sh
```

脚本优先使用 `mydailypython`，不存在时使用 `python3`。检查包括 Python 语法、EXIF 时间命名、修改时间回退、重名编号、旧名称转换、重复运行，以及图片内容保持不变。测试只操作临时生成的图片，不启动界面、不修改个人照片；这不等同于所有图片格式和界面行为都已验证。

## ImageOptim 原生集成方案

已选择修改现有 [ImageOptim](https://github.com/ImageOptim/ImageOptim) 的路线，以 Objective-C 和 macOS ImageIO/Foundation 实现重命名，保留成熟压缩引擎。第一版优先验证 JPEG、PNG，增加默认关闭的“压缩前按拍摄时间重命名”选项，并沿用当前纯时间命名规则。

计划顺序：

1. 获取独立的上游源码副本并记录版本，先完成未加入重命名功能的原版构建验证。
2. 根据实际构建结果调整本机签名配置和失效下载地址。
3. 实现独立重命名模块，在原始 EXIF 或文件时间被压缩流程改变前读取时间，并在压缩任务使用路径前完成改名。
4. 更新列表和任务路径；重命名失败时显示原因并跳过该文件的压缩。
5. 验证完整流程，生成与官方应用可区分的本机定制版本。

原生版需要额外验证：元数据清理后重复处理仍不会再次改名、名称冲突不覆盖文件、中文和空格路径、只读文件、批量任务，以及集成前后的压缩功能。现有 Python 的重复处理规则不能直接当作压缩后仍然有效的保证。

### 构建依赖与待处理事项

- Xcode 提供 Objective-C 编译器和 macOS SDK；ImageIO/Foundation 无需另装。
- 按上游说明使用 rustup 管理 Rust。Rust 用于构建部分压缩引擎，新增重命名模块本身不依赖 Rust。
- SVG 相关构建流程使用 Node.js/npm；还需要 Git、Make 和外部依赖下载访问。
- 当前只验证了 Apple Silicon 本机目标；如需兼容 Intel，需补齐相应目标并验证。
- 上游脚本包含 `Developer ID` 签名步骤，计划为本机版本调整签名方式；尚未验证完整应用的签名和启动。
- 已检查的 SourceForge 旧 HTTP 地址访问失败，HTTPS 版本检查通过；历史 AdvanceCOMP 归档地址返回网页，仍需核实下载内容。

以上是环境检查和计划，不表示完整 ImageOptim 已经构建成功。原生构建流程确定后再增加对应 `run_*.sh`，将准备、构建和验证步骤写入文档。

## 文件结构

| 文件 | 用途 |
| --- | --- |
| `photo_time_renamer.py` | 当前重命名逻辑和 Tkinter 界面 |
| `test_renaming.py` | 临时图片回归检查 |
| `run_app.sh` | macOS 终端启动入口 |
| `RunPhotoTimeRenamer.command` | Finder 双击启动入口和 Python 环境选择 |
| `run_checks.sh` | 语法与重命名检查入口 |
| `AGENTS.md` | 项目协作规则 |
| `.gitignore` | 本地缓存和构建产物排除规则 |

这是日常图片工具项目，长期决策和运行说明集中维护在本 README 中。
