# 任务4：网络控制与实时显示

## 文件

- monitor_network.py
- protocol.py
- web_common.py
- mock_ps_server.py
- test_network.py

## 与任务3的对应关系

上位机上传图片后自动发送：

~~~text
SET_THRESHOLD -> DATA_REG
SET_MODE      -> MODE_REG
START_ANALYZE -> CMD_REG=1
~~~

显示模式仍只控制本地上位机画面，不再直接写PL MODE_REG，避免和单图/视频流模式混淆。

## 本地测试

终端1：

~~~powershell
python mock_ps_server.py --host 127.0.0.1
~~~

终端2：

~~~powershell
python monitor_network.py --board-ip 127.0.0.1 --threshold 128 --pl-mode 1 --no-browser
~~~

浏览器打开：

~~~text
http://127.0.0.1:8765/
~~~

点击上传图片后，模拟PS会收到阈值、模式和START命令。

## 自动测试

~~~powershell
python -m unittest test_network.py -v
~~~
