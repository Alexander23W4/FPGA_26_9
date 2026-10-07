# CAMUS 任务二完成报告

## 一、数据完整性检查

- 数据目录：C:/Users/13995/Desktop/fpga校赛/CAMUS_public
- 患者目录：500个，patient0001～patient0500
- 每例文件数：15个
- 缺失文件：0
- 官方划分文件：training、validation、testing、information、license全部存在
- 原始数据总量：约3.66 GB

结论：下载数据完整，满足任务二转换需要。

## 二、转换结果

- 转换组合：2000组
- 转换成功：2000组
- 转换失败：0组
- 训练集：1600组
- 验证集：200组
- 测试集：200组
- 输出文件：16001个
- 输出总量：约0.804 GB

输出根目录：

C:/Users/13995/Desktop/fpga校赛/camus_processed

每组数据包含：

- 256×256、8 bit灰度PNG
- 65536字节、无文件头BIN
- Vivado BRAM初始化COE
- 输入几何、归一化、缩放和SHA256元数据JSON
- GT标签BIN/PNG
- GT二值掩膜BIN/PNG

## 三、自动校验结果

校验2000组数据，错误0组。校验内容包括：

1. PNG尺寸为256×256。
2. BIN文件大小为65536字节。
3. COE解析后的65536个值与BIN逐字节一致。
4. PNG像素与BIN逐像素一致。
5. GT标签只包含0、1、2、3。
6. 二值掩膜只包含0、1。
7. JSON中的SHA256与实际文件一致。

## 四、处理规则

- 超声图像使用1%～99%分位数裁剪并归一化至0～255。
- 使用等比例缩放加零填充，不直接拉伸图像。
- GT使用最近邻插值，避免产生不存在的标签类别。
- BIN按行优先、每像素1字节排列。
- COE数值顺序与BIN完全一致。
- JSON中的valid_bbox_xywh表示原图有效区域，黑色填充区不属于有效图像。

## 五、交付文件

- 转换脚本：C:/Users/13995/Desktop/fpga校赛/camus_pipeline/tools/convert_camus.py
- 校验脚本：C:/Users/13995/Desktop/fpga校赛/camus_pipeline/tools/validate_outputs.py
- 使用说明：C:/Users/13995/Desktop/fpga校赛/camus_pipeline/README.md
- 数据清单：C:/Users/13995/Desktop/fpga校赛/camus_processed/manifest.csv

## 六、注意事项

CAMUS是心脏超声数据集，不是CT。当前结果可用于验证灰度归一化、阈值分割、轮廓提取、面积统计和显示链路，但不能直接用于证明CT层厚与三维体积换算。若BRAM为32位，需要在Vitis端将4个连续字节按小端格式打包后写入。
