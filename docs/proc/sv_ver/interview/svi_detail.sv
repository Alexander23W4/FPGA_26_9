
// What is the Difference between SystemVerilog packed and unpacked array?
bit [2:0][7:0] a;     // 两个 packed 维度
bit [7:0] b [2:0];    // 一个 packed 维度 + 一个 unpacked 维度

// in SystemVerilog which array type is preferred for memory declaration and why?
logic [7:0] mem [0:1023];




// What is the difference between logic and bit in SystemVerilog?

/*
SystemVerilog 中，bit 和 logic 的核心区别是：
    bit 是二态数据类型，只能表示 0 和 1；             默认值为 0。
    logic 是四态数据类型，可以表示 0、1、X 和 Z。     默认值为 X。

    X：未知值，例如仿真中尚未初始化的寄存器。
    Z：高阻态，常用于建模三态信号。
*/


// What is the difference between datatype logic and wire?
// 这里要强调 过程赋值  连续赋值  这两个定义





// What is the difference between == and === ?
// == 和 === 的核心区别是：== 会受到 X、Z 等未知或高阻值的影响，=== 则会把 X、Z 当作明确的比较值进行匹配。

module tb;
    logic [3:0] a, b;

    initial begin
        a = 4'b10X1;
        b = 4'b10X1;

        $display("==  : %b", a == b);   // 结果是X
        $display("=== : %b", a === b);  // 结果是1
    end
endmodule

// What are the system tasks?
// 系统任务  带$的task



// What are the different types of verification approaches?  验证方法/角度

/*
验证方法	核心思想	典型用途
Directed Testing 定向测试	手动编写特定输入，验证预期行为	复位、边界条件、特定协议场景
Constrained-Random Testing 约束随机测试	在约束条件下随机生成输入，探索大量场景	UVM 验证、复杂状态组合
Coverage-Driven Verification 覆盖率驱动验证	根据覆盖率反馈，补充测试直到达到目标	确认功能场景是否充分覆盖
Assertion-Based Verification (ABV) 断言验证	用断言检查信号之间的时序和逻辑关系	握手协议、时序要求、状态机约束

Formal Verification 形式化验证	用数学方法证明设计满足属性或检查等价性	FIFO、仲裁器、控制逻辑、等价性检查

Emulation 硬件仿真加速	在专用硬件平台上运行设计	大型 SoC、操作系统和软件验证
FPGA Prototyping FPGA 原型验证	将设计映射到 FPGA 上运行	系统集成、驱动和真实软件验证
*/


// What are the basic testbench components?  验证环境组件
/*
Test / Test Scenario
配置测试、决定测试场景

Generator / Sequence
生成测试事务（Transaction）

Driver
将事务转换为 DUT 引脚上的信号活动

DUT
被测设计，例如 FIFO、CPU 或总线控制器

Monitor
采集实际信号

Scoreboard
比较实际结果与预期结果

Coverage
统计场景覆盖情况
*/


// What are the different layers of layered architecture? 验证环境的 层级结构
/*
Test Layer
选择测试场景、配置验证环境

Scenario / Sequence Layer
定义事务序列与激励场景

Functional Layer
生成、组织和处理事务；协调验证组件

Command / Pin-Level Layer
将事务转换成具体信号和时序操作

DUT Interface
与被测 RTL 的实际端口交互
*/


// What is the difference between a $rose and @ (posedge)?


// What is the difference between blocking and non-blocking assignments?

/*
1. Blocking assignment：=
在当前过程执行到赋值语句时，立即更新左侧变量，然后继续执行后续语句。

2. Non-blocking assignment：<=
右侧表达式在执行该语句时求值，左侧变量的更新则安排在当前时间步的 NBA（Non-Blocking Assignment）区域进行。
*/



// Explain the difference between new( ) and new[ ] ?


