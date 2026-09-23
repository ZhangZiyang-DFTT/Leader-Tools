# Leader Tools 1.1.6

macOS 十秒数字 Head / Tail Leader。独立片名 / 本号 / 备注信息卡、双时钟、本号、时间码，以及 TIFF / ProRes 422 HQ 输出。

Developed by [ZhangZiyang-DFTT](https://github.com/ZhangZiyang-DFTT) in collaboration with OpenAI Codex.

## 下载

- [下载 Leader Tools 1.1.6 DMG](https://github.com/ZhangZiyang-DFTT/Leader-Tools/releases/download/v1.1.6/Leader_Tools_1.1.6.dmg)
- [版本说明与附件](https://github.com/ZhangZiyang-DFTT/Leader-Tools/releases/tag/v1.1.6)

安装包适用于 Apple Silicon Mac，构建目标为 macOS 13 及以上；不支持 Intel Mac。安装包与源码分开发布；无需下载源码或安装开发依赖即可运行应用。

TIFF/MOV 的范围说明及 Resolve Full 读取校正限制见 [使用指南](Resources/Guide.html)、[Resolve Full 读取说明](Resources/Resolve_Full_Readme.txt) 和 Release 附件。

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
- 第四本 Tail 的 2-pop 在 `2*nominalFPS-1` 索引，距离相邻 LFOA 帧首两个标称秒。
- Head 末帧下三角、Tail 首帧上三角固定。END OF REEL 只出现在 Tail 最后一帧。
- 片名、本号、备注仅出现在独立卡片上。24 FPS 的 Head 信息段为索引 1–20 / 21–25 / 26–47；索引 48 仅有“开始 / PICTURE START / 装在片门”。
- 三条 COMMAG / COMOPT 文字分别只在剩余 172 / 170 / 164 帧出现一帧，画面仍是正常双时钟，文字位于左侧帧数时钟下方。`SOUND START` 位于 EBU `START` 的原始剩余 144 参考帧，其他时基按标称帧率映射。

TIFF：`影片名_R04_HEAD_24FPS_1998x1080_Rec709_Full.00345360.tif`

MOV：`影片名_R04_TAIL_23.976FPS_1998x1080_Rec709_Video.mov`

TIFF 的点号后是时间码实际累计帧数，不是从 0 开始的局部帧号。每本放在 R04 等目录，`TIFF10_COMPAT` / `ProRes422HQ` 子目录区分存储编码。CSV、manifest 与 TIFF 描述同时记录逐帧时间码，MOV 则另有真实 tmcd 轨。

## 第三方声明

本项目原始代码暂不授予开源许可；第三方组件遵循各自许可证。组件清单见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，完整声明见 [ThirdPartyNotices.txt](Resources/ThirdPartyNotices.txt)，也可在应用“帮助 > 第三方组件与许可证”中查看。
