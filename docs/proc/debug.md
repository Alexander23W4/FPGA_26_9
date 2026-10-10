
# practice流程
1. 第一阶段：小模块 Debug。 用 XSim 创建一个简单 Testbench，学会产生时钟、复位、输入激励，观察内部寄存器和组合逻辑。
2. 第二阶段：自动检查。 在 Testbench 中增加 if 检查、$display、$fatal，让错误能够自动暴露，而不是依赖人工观察每一条波形。
3. 第三阶段：系统级仿真。 把多个 RTL 模块集成到一个 DUT，模拟真实接口和数据流，检查端到端输出。
4. 第四阶段：Reference Model / DiffTest。 图像处理用 Python 生成 Golden Data；CPU 或需要紧密同步的模型可以研究 DPI-C。
5. 第五阶段：SVA、覆盖率、UVM。 当手工测试难以覆盖所有情况、模块数量和接口复杂度显著增加时，再引入这些机制。

归纳一下：你在 Vivado 下做纯 RTL 功能验证，主要工具就是 XSim；小模块看波形用 Testbench 驱动，大系统用系统级 Testbench 检查整体行为，和 C/Python 对拍则在 Testbench 上增加 Reference Model 与比较机制。 UVM 是可选的验证架构，不是入门 Debug 的前置条件。

# 对比 ★★★★★
## 功能	                你在 ysyx/NPC 中的环境	                     Vivado 下的对应方式

RTL 仿真器	                Verilator	                                    XSim
驱动 RTL、产生激励	        C/C++ TB、wrapper	            SystemVerilog Testbench，也可通过 DPI-C 等方式接入 C
查看内部信号波形	        Verilator --trace + GTKWave	                XSim + Wave 窗口
自动构建与运行	            Makefile、编译选项、obj_dir/Vtop	     Vivado 仿真流程，或 Tcl 脚本驱动
C 参考模型	                NEMU REF	                            可以继续使用现有 C 参考模型
差分测试	                NPC DiffTest，对比 DUT 与 NEMU	    Testbench/Scoreboard 对比 DUT 与 REF
指令执行追踪	            PC、指令 trace、GDB/SDB 等	        XSim 波形、$display、$monitor、自定义 trace
RTL 静态检查	            Verilator --lint-only	            Vivado RTL Analysis、语法检查及相关综合检查
自动化测试	                Make target、测试程序、回归脚本	        Tcl/批处理 + Testbench + 自动检查

形式验证	                你此前探索过的 BMC / SMT 流程	    需要另外配置适用的形式验证工具或流程，不是 XSim 波形仿真的替代品


# 用xsim + wave 首次debug小结
debug了threshold, 观察reg对axi_lite信号的响应和输出响应

和verilator的c环境仿真做下对比: 环境搭建  tb供给  输出查看

verilator基本上全方位碾压
    tb供给用c语言好过用verilog的仿真语言  
    输出查看xsim仅波形与verilog仿真display输出, verilator可用gdb+printf输出+gtwave波形



