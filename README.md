# PhotoWorkbench

**0.9 · macOS · Apple Silicon**

按文件创建时间批量重命名图片，并使用 [ImageOptim](https://imageoptim.com/) 的压缩后端优化 JPEG 和 PNG。重命名与压缩是两个独立操作，添加图片不会自动修改文件。

## 功能

- **批量重命名**：使用 Finder 中的文件创建时间（Created），按本机时区生成 `yyMMddHHmmss.ext`，也可保留原文件名作为前缀。同名自动编号，不覆盖已有文件。
- **图片压缩**：默认严格无损并保留元数据；可在设置中明确开启有损压缩或移除元数据。仅保存更小且通过校验的结果。
- **撤销与恢复**：当前会话内可撤销重命名、恢复压缩前的内容；压缩原件保留在废纸篓。
- **预览与整理**：拖入图片或文件夹，空格或双击 Quick Look，右键在 Finder 中显示文件。

| 格式 | 重命名 | 压缩 |
| --- | --- | --- |
| JPEG / JPG、PNG | 支持 | 支持（APNG 除外） |
| HEIC / HEIF、WebP | 支持 | 暂不支持 |

## 获取与运行

需要 **Apple Silicon Mac、macOS 15 或更新版本**，界面为英文。目前仓库提供源码，尚未提供可下载的应用发行附件。

已有 `PhotoWorkbench.app` 时，直接打开即可；运行成品不需要 Python、Homebrew 或另外安装 ImageOptim。当前成品仅做本机临时签名，尚未经过 Apple 公证。

从源码构建需要完整 Xcode、Python 3，以及用于提取固定版本引擎的 ImageOptim 1.9.3：

```bash
git clone https://github.com/sunsellingowl/PhotoWorkbench.git
cd PhotoWorkbench
bash run_build.sh
open dist/PhotoWorkbench.app
```

首次构建会下载并校验固定依赖，后续构建复用本地依赖。详细要求与开发检查见 [开发说明](docs/DEVELOPMENT.md)。

## 使用

1. 将图片或文件夹拖入窗口，或点击 **Add**。
2. 点击 **Rename** 重命名，或点击 **Compress** 压缩。
3. 需要撤销时，使用 **Undo Rename** 或 **Restore Originals**。

两个处理按钮都会处理列表中全部适用图片；选中行用于预览和 Finder 操作。**Stop** 取消剩余任务，已完成的结果会保留。**Clear** 和移除列表项不会删除图片。

重命名不使用 EXIF 拍摄日期或修改时间。撤销和恢复记录在退出后清空；外部修改、备份丢失或路径冲突可能使撤销或恢复被拒绝。开始前请保留重要图片的独立备份。

## 原作与致谢

本项目基于 **Kornel Lesiński 及 ImageOptim 贡献者**的工作，复用了 ImageOptim 的 Objective-C 压缩后端及其调用的第三方引擎。压缩算法与相关上游成果的著作权归原作者及相应权利人所有。

PhotoWorkbench 新增了 SwiftUI 界面、按文件创建时间重命名、候选结果校验和安全保存适配；上游修改保存在 [`patches/imageoptim.patch`](patches/imageoptim.patch)。本项目并非 ImageOptim 官方发行版，也不代表原作者背书。

- 原版软件：[ImageOptim 官网](https://imageoptim.com/)
- 原版源码：[ImageOptim/ImageOptim](https://github.com/ImageOptim/ImageOptim)
- 复用后端的固定提交：[`8a4651e`](https://github.com/ImageOptim/ImageOptim/tree/8a4651e14ca53022f6a318071d08bb132fc56ce9)
- 第三方组件、来源与许可：[THIRD_PARTY.md](THIRD_PARTY.md)

## 开源许可

PhotoWorkbench 的项目自有代码以 **GNU GPL v2 或更新版本（GPL-2.0-or-later）** 授权，许可证全文见 [LICENSE](LICENSE)，项目授权声明见 [COPYRIGHT](COPYRIGHT)。不提供任何担保。复用的 ImageOptim 后端遵循其 GPL v2 或更新版本许可，其他组件保留各自的版权与许可证。

请保留原作者署名、版权声明和许可证，并按各组件的许可使用、修改和分发。PNGOUT 为单独许可的闭源工具，不属于本项目可重新授权的源码；分发捆绑应用前须另行确认引擎许可及对应源码要求。
