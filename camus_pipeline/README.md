# CAMUS 数据转换工具

本目录也包含 CardiacUDC cine 序列转换工具，见下方“CardiacUDC 流模式”。

## 转换范围

已将 CAMUS_public 中全部 500 例患者的四个静态时相转换为 FPGA 工程可用格式：

- 2CH_ED
- 2CH_ES
- 4CH_ED
- 4CH_ES

共 2000 组图像与标注，未处理 half_sequence。

## 输出内容

每组数据输出：

- 256×256、8 bit 灰度 PNG
- 65536 字节、无文件头 BIN
- Vivado BRAM 初始化 COE
- 原图几何、归一化、缩放、填充和校验信息 JSON
- GT 标签 PNG/BIN
- GT 二值掩膜 PNG/BIN

## 处理规则

1. 使用 Python 直接解析 NIfTI-1 单文件头，不依赖 SimpleITK 或 nibabel。
2. 对超声图像使用 1%～99% 分位数裁剪，归一化到 0～255。
3. 使用等比例缩放加零填充，避免直接拉伸造成形状失真。
4. GT 使用最近邻插值，保留 0、1、2、3 标签；非零标签合并生成二值掩膜。
5. 原图未被修改，转换结果写入独立目录。

## 运行

单例转换：

~~~powershell
python convert_camus.py --patients patient0001 --overwrite
~~~

全部转换：

~~~powershell
python convert_camus.py --overwrite
~~~

校验全部输出：

~~~powershell
python validate_outputs.py "C:/Users/13995/Desktop/fpga校赛/camus_processed"
~~~

## 说明

CAMUS 是心脏超声数据，不是 CT。当前转换结果用于验证医学灰度影像处理、阈值分割、轮廓提取和显示链路。CT层厚和三维体积换算需要后续使用带物理层厚的公开 CT 数据验证。

## 数据许可

CAMUS 使用 CC BY-NC-SA 4.0，仅允许非商业科研用途。引用要求见 CAMUS_public/database_split/LICENSE_TERMS.md 和 information.txt。

## CardiacUDC 流模式

`tools/convert_cardiacudc.py` 用于把 `cardiacUDC_dataset` 中的 NIfTI cine 图像拆成逐帧 BIN，供 FPGA GUI 的“选择流文件夹”使用。它和上面的 CAMUS 静态时相转换是两套输入格式。

PowerShell 示例：

~~~powershell
& 'E:/PythonVersionEnv/Python3.14.0/python.exe' `
  'C:/Users/HUAWEI/Desktop/FPGA_26_9/camus_pipeline/tools/convert_cardiacudc.py' `
  --input 'E:/cardiarc_extract/cardiacUDC_dataset' `
  --output 'E:/cardiarc_extract/cardiacUDC_gui_ready'
~~~

输出按站点和病例分开，例如：

~~~text
cardiacUDC_gui_ready/
  manifest.csv
  sequences/
    Site_G_100/patient1-4/000000.bin
    Site_G_100/patient1-4/000001.bin
    ...
~~~

GUI 中选择 `sequences/Site_G_100/patient1-4` 作为流文件夹。帧文件名补足六位数字，确保按 NIfTI 的帧轴顺序播放。每个 BIN 是无头文件的 256×256、8-bit 灰度数据，恰好 65,536 字节。GUI 按自己的发送速度循环播放，不会保留 NIfTI 中未提供的采集时间间隔。

CardiacUDC 的源像素已是 8-bit；转换保留像素灰度范围，不做逐帧自动对比度拉伸。图像按 NIfTI 的 x/y 轴转为屏幕行列方向，并将超声扇区尖端统一放在上方；随后按比例缩放并居中补黑边，避免把 4:3 超声图像拉伸成正方形。标签不混入 GUI 输入目录；`manifest.csv` 会标出对应标签是否存在。

先试转前两段序列：

~~~powershell
& 'E:/PythonVersionEnv/Python3.14.0/python.exe' `
  'C:/Users/HUAWEI/Desktop/FPGA_26_9/camus_pipeline/tools/convert_cardiacudc.py' `
  --input 'E:/cardiarc_extract/cardiacUDC_dataset' `
  --output 'E:/cardiarc_extract/cardiacUDC_gui_ready' `
  --limit 2
~~~

若要重跑已有输出并覆盖同名 BIN，加 `--overwrite`。转换不会修改 NIfTI 源文件。
