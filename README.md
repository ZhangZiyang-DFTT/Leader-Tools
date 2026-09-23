# Leader Tools 1.1.6

原生 macOS 十秒数字 Head / Tail Leader。独立片名 / 本号 / 备注信息卡、双时钟、固定边界三角、本号 NDF 时间码，以及 TIFF / ProRes 422 HQ 输出。三条 COMMAG / COMOPT 声画同步文字分别在原始帧位的正常双时钟画面上出现一帧；每秒仅反转时钟，2-pop 才全屏反转，橙黄色帧位数字始终保留原色。

Developed by [ZhangZiyang-DFTT](https://github.com/ZhangZiyang-DFTT) in collaboration with OpenAI Codex.

由 ZhangZiyang-DFTT 主导需求、电影工作流程设计与验收，OpenAI Codex 协助代码实现、测试和文档编写。

## 许可与第三方声明

本项目原始代码暂未授予开源许可；公开可见不等于另行授权使用或再分发，相关许可请联系维护者。第三方组件仍遵循各自原有许可证，不受此限制影响。

组件、版本、来源与分发范围见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，完整声明见 [ThirdPartyNotices.txt](Resources/ThirdPartyNotices.txt)。声明同时随应用和 DMG 提供，可通过应用的“帮助 > 第三方组件与许可证”查看。LibTIFF 是随应用分发的库，zlib 来自系统；Python/PyAV/FFmpeg 等仅用于开发验收。

## 下载

- [下载 Leader Tools 1.1.6 DMG](https://github.com/ZhangZiyang-DFTT/Leader-Tools/releases/download/v1.1.6/Leader_Tools_1.1.6.dmg)
- [版本说明与附件](https://github.com/ZhangZiyang-DFTT/Leader-Tools/releases/tag/v1.1.6)

安装包适用于 Apple Silicon Mac，构建目标为 macOS 13 及以上；不支持 Intel Mac。当前为 ad-hoc 签名，尚未完成 Apple Developer ID 签名和公证。安装包与源码分开发布；无需下载源码或安装开发依赖即可运行应用。

TIFF/MOV 的范围说明及 Resolve Full 读取校正限制见下方“像素管线”和 Release 附件。

## 运行与构建

Apple Silicon，macOS 13 构建目标。静态 LibTIFF、系统 zlib、AVFoundation、CoreGraphics / CoreText 和 SwiftUI；应用运行不需要 Python、FFmpeg、Homebrew 或网络。ad-hoc 签名，未进行 Apple Developer ID 签名或公证。

```bash
bash build.sh
"build/Leader Tools.app/Contents/MacOS/LeaderTools" --self-test QA
"build/Leader Tools.app/Contents/MacOS/LeaderTools" --review-stills QA/Stills
bash package.sh "/absolute/path/Leader_Tools_1.1.6.dmg"
```

构建需要 Xcode Command Line Tools、Python 3（仅标准库，用于第三方声明校验）和正常访问系统图标 / ProRes 服务。打包脚本不覆盖已有同名 DMG。

## 使用

片名限 1–15 字，支持中文并自动适配字号。输入起止本号 1–23；备注最多 400 字 / 12 行。Logo 可选 PNG / JPEG / TIFF，最多 20 MB，保存在预设中，出现在备注卡而非时钟或黑场。界面可载入 / 保存 JSON 预设。

```bash
"build/Leader Tools.app/Contents/MacOS/LeaderTools" \
  --generate --output "/absolute/path/Leaders" \
  --title "示例影片" --reels 4:5 --fps 24 --size 1998x1080 \
  --notes "画面版本：正式交付" --mov
```

默认导出 10-bit 有效精度 TIFF，使用通用的 16-bit RGB 容器；旧版 `--storage 10` / `--storage 16` 命令均会自动转为这一兼容格式。`--mov` 同时输出 MOV，`--mov-only` 只输出 MOV。`--head-only` / `--tail-only` 选择种类，`--video` 设置 TIFF Video 范围，`--logo PATH` 载入 Logo，`--no-audio` / `--no-compress` / `--mono` 为可选开关。其余见 `--help`。

## 时序与命名

完整逐帧规则、规范来源及数字适配差异见 `Resources/Guide.html`。

- 十个标称秒：`frameCount = 10 * nominalFPS`，实际帧时长为精确分母 / 分子，统一 NDF。
- 23.976 / 29.97 / 59.94 / 239.76 分别有 240 / 300 / 600 / 2400 帧，每段 10.01 实秒，不丢帧、不重复帧。
- 第四本 Head 从 `03:59:50:00` 开始，`03:59:52:00` 为 PICTURE START，FFOA 参考为 `04:00:00:00`。
- 第四本 Tail 独立从 `04:00:00:00` 开始，不依赖正片时长。其 2-pop 在 `2*nominalFPS-1` 索引，距离相邻 LFOA 帧首两个标称秒。
- Head 末帧下三角、Tail 首帧上三角固定。END OF REEL 只出现在 Tail 最后一帧。
- 片名、本号、备注仅出现在独立卡片上。24 FPS 的 Head 信息段为索引 1–20 / 21–25 / 26–47；索引 48 仅有“开始 / PICTURE START / 装在片门”。
- 三条 COMMAG / COMOPT 文字分别只在剩余 172 / 170 / 164 帧出现一帧，画面仍是正常双时钟，文字位于左侧帧数时钟下方。`SOUND START` 位于 EBU `START` 的原始剩余 144 参考帧，其他时基按标称帧率映射。

TIFF：`影片名_R04_HEAD_24FPS_1998x1080_Rec709_Full.00345360.tif`

MOV：`影片名_R04_TAIL_23.976FPS_1998x1080_Rec709_Video.mov`

TIFF 的点号后是时间码实际累计帧数，不是从 0 开始的局部帧号。每本放在 R04 等目录，`TIFF10_COMPAT` / `ProRes422HQ` 子目录区分存储编码。CSV、manifest 与 TIFF 描述同时记录逐帧时间码，MOV 则另有真实 tmcd 轨。

## 像素管线

绘图使用 Rec.709 的 32-bit float RGBA 画布。黑白实色使用 0 / 1，反相后互换；时钟灰阶、橙色和抗锯齿保留。TIFF 为 `BitsPerSample=16,16,16`、无 Alpha，两个范围均使用 `round(q10*65535/1023)`。Full 黑白为 0 / 65535；Legal 为 4100 / 60218。以 Full 归一化读取后，分别约为 64.0009 / 940.0017，四舍五入恢复 10-bit 的 64 / 940。16-bit 整数无法精确表达所有 q10/1023，但不会再产生整整一个码值的偏差。采用无压缩或 Deflate 无损。

MOV 使用系统 Apple ProRes 422 HQ 编码器；浮点 RGB 经 Rec.709 矩阵转换至原生 10-bit v210 Video 范围，以 4:2:2 编码，未经过 8-bit 中间图。MOV 的 Video 命名如实反映 YCbCr 范围，与 Full RGB TIFF 不同。48k / 24-bit PCM 同步音轨与 WAV 使用相同的帧边界采样计算。

本机 Resolve 21.1.0.14 的 ProRes Full 解码实测为 `q10*64/65535`，原始白 940 因而读作约 939.096。每个 MOV 批次附带 `Resolve_Full_Readback`，内含浮点 DCTL 及说明，可在该 Full 读取路径中恢复 64/940；不改变源文件，不把白色编码成非标准的 941。校正不得用于 TIFF、Video/Auto 或已经正确归一化的解码器。详见 `Resources/Resolve_Full_Readme.txt`。该兼容措施需要接收端应用，MOV 在上述 Resolve 路径中直接读取仍会有偏差。

每种尺寸在自身宽高比内布局，不以固定 16:9 画布加黑边伪装其他画幅。圆形等比缩放；预览显示真实输出边框。DCI 尺寸不是 DCDM / XYZ 色彩合规声明。

## 验收

内置自测覆盖全部帧率、NDF 时基、本号时间码、独立信息卡、同步帧、全周等角刻度、时钟局部反相、2-pop 全屏灰阶反相、橙黄色保留、10-bit 有效精度、八种分辨率的 LibTIFF 与 ImageIO 双重解码，以及批量输出。`--verify FILE...` 使用 LibTIFF 解码并显示容器位深与码值。

独立验证使用 Python 虚拟环境安装 `Tools/qa-requirements.txt` 后执行：

```bash
python Tools/verify-delivery.py --root "/absolute/path/Leaders" --report "/absolute/path/QA.json"
```

脚本使用 tifffile / imagecodecs 读取 TIFF，PyAV / FFmpeg 解码 MOV，验证 ProRes HQ、10-bit 4:2:2、有理时基、时间码、完整帧数、纯黑、同步音频和序列命名。Python 依赖仅用于开发验收。

输出使用唯一 `.partial` 批次；全部完成后改为最终目录。取消 / 失败保留文件和状态，磁盘空间不足时会停止。

## 依赖复现

LibTIFF 4.7.1 源码归档在 `Vendor/Source/tiff-4.7.1.tar.gz`，上游 <https://download.osgeo.org/libtiff/tiff-4.7.1.tar.gz>。

SHA-256：`f698d94f3103da8ca7438d84e0344e453fe0ba3b7486e04c5bf7a9a3fabe9b69`。

执行 `bash Tools/build-libtiff.sh` 可校验并重建 ARM64 / macOS 13 静态库，只使用系统 zlib。许可在 `Resources/ThirdPartyNotices.txt`。模块：`Model.swift` 时序 / 设置、`Renderer.swift` 浮点绘图、`MovieWriter.swift` ProRes / 音频 / 时间码、`Exporter.swift` 批量写入、`AppView.swift` 界面、`CLI.swift` 命令行与测试。
