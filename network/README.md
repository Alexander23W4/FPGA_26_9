# network_v2：对齐队友主工程接口的版本

## 基准

来自队友仓库：

- rtl/axi_lite_rcv.v
- csrc/MID_plt/src/config/pl_cmd.h
- scripts/tcl/create_zynq_project.tcl

AXI-Lite：

~~~text
PL_REG_BASEADDR = 0x44000000
0x00 MODE
0x10 CMD
0x20 DATA
0x30 DBG0
0x34 DBG1
0x38 DBG2
0x3C DBG3/STATUS
0x40 DBG4
~~~

主图像链：

~~~text
PS DDR
  -> AXI VDMA MM2S，64位
  -> top1
  -> axi2px
  -> 8位像素流
~~~

## 任务3

ps_baremetal目录中的网络服务器接收图片到DDR，然后调用队友仓库的：

~~~text
vdma_mm2s_stop
vdma_mm2s_reset
vdma_mm2s_config
vdma_mm2s_start
~~~

随后写：

~~~text
MODE_REG = SINGLE_MODE
DATA_REG = threshold
CMD_REG  = REOPERATE
~~~

## 任务4

host目录中的上位机上传图片后自动发送阈值、模式和START命令。

## 本地测试

~~~powershell
cd mock
python mock_ps_server.py --host 127.0.0.1
~~~

另一个窗口：

~~~powershell
cd host
python monitor_network.py --board-ip 127.0.0.1 --no-browser
~~~

浏览器打开：

~~~text
http://127.0.0.1:8765/
~~~

## 自动测试

~~~powershell
cd host
python -m unittest test_network.py -v
~~~
