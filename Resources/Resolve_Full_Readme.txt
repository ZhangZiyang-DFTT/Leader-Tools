Leader Tools 1.1.6 - DaVinci Resolve Full 读取说明

TIFF：本版 Legal 黑白存为 16-bit RGB 的 4100 / 60218。
片段属性 Data Levels 设 Full，按 0-1023 测量，黑白四舍五入为 64 / 940。
不要对 TIFF 应用附带的 DCTL。Full TIFF 仍为 0 / 65535。

MOV：原始 ProRes 422 HQ 的 Y 码值为标准 Legal 64 / 940。
本机 Resolve 21.1 的 Full 解码路径将 q10 左移六位，再除以 65535，
因此 940 显示约 939.096，而不是文件中真的写了 939。
不能把源白写成 941 来修正这个读取差异，那会改变标准 Legal 端点。

仅在确认上述 Full 解码偏差的 DaVinci Resolve Studio 中：
1. 项目设置 > 色彩管理 > 打开 LUT 文件夹。
2. 将 LeaderTools_Resolve_Full_ProRes_Q10.dctl 放入该文件夹并刷新 LUT。
3. MOV 片段属性 Data Levels 设 Full。
4. 在未经其他调色、未进行色彩空间变换的第一个串行节点上应用此 DCTL。
   在普通 DaVinci YRGB / Rec.709 工程中使用；不要套在 RCM/ACES 变换之后。
5. 用 10-bit 标尺检查平坦黑白区域，应为 64 / 940。

这个 DCTL 只补偿 65535/(1023*64) 的归一化差异，不限幅、不改变伽马。
不要用于 TIFF、Auto/Video 读取、已经正确显示 940 的解码器，也不要重复应用。
它是读取端兼容处理，不是写入 MOV 的调色，也不是要求所有接收端使用 LUT。
其他 Resolve 版本/硬件路径请先用样片复测；本次实测版本为 21.1.0.14。

抗锯齿边缘、刻意设计的灰色区域和有损编码振铃并不都是纯黑/纯白，
验收端点应在连续平坦黑白区域内采样，不应以全图极值代替。
