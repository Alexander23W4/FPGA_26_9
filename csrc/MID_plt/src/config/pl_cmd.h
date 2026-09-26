/*
选择模式:
# (单图模式) arm 向 MODE_ADDR 写入 SINGLE_MODE

    载入图片:
    >> arm 把新图片放到 SINGLE_IMG_ADDR

    写入阈值:
    >> arm 把新data值写到 DATA_REG_ADDR, pl 作为slave 自动相应, 更新 

    开始分析:
    >> arm 向 CMD_REG_ADDR 写入 REOPERATE
    >>> pl 从 SINGLE_IMG_ADDR 读取图片再 operate 一遍, 然后清空 控制寄存器


上位机操作大致就是:
页面1: 先点"选择模式", 选择"单图模式", 然后进入单图模式页面
页面2(单图模式页面): 先点"载入图片", 选择本地路径(.bin文件).  再点"写入阈值"(后续再加其他数据写入).  最后点"开始分析"

*/

#define SINGLE_IMG_ADDR 0x10000000
#define SINGLE_IMG_LEN  0x20000

// 这两个是伪地址, pl读到这个地址就知道是 写 模式寄存器/控制寄存器/数据寄存器
#define MODE_ADDR     0x01
#define CMD_REG_ADDR  0x10
#define DATA_REG_ADDR 0x20

// 模式指令 (单图模式/视频流模式)
#define SINGLE_MODE 0x01
#define STREAM_MODE 0x02

// 控制指令
#define REOPERATE 0x01



