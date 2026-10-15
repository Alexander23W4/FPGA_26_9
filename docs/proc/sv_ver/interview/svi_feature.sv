
// What is the difference between an initial and final block of the systemverilog?
module itv;
    initial begin
        
    end

    final begin
        
    end

endmodule



// What is SystemVerilog assertion binding and advantages of it?
// bind 使得 assertion 能够从DUT中独立出来 放到仿真模块里面
module fifo (
    input logic clk,
    input logic rst_n,
    input logic wr_en,
    input logic full
);
    // FIFO RTL implementation
endmodule

module fifo_assert (
    input logic clk,
    input logic rst_n,
    input logic wr_en,
    input logic full
);
    property no_write_when_full;
        @(posedge clk)
        disable iff (!rst_n)
        full |-> !wr_en;
    endproperty

    assert property (no_write_when_full);
endmodule

bind fifo fifo_assert u_fifo_assert (   // bind    ★ 可以绑定到具体实例, 也可以泛泛地绑定到module(将自动绑定所有实例)
    .clk   (clk),
    .rst_n (rst_n),
    .wr_en (wr_en),
    .full  (full)
);



// ★★★ What is DPI?
/*
DPI（Direct Programming Interface）是 SystemVerilog 与 C/C++ 之间的直接调用接口。

如果没有 DPI，你需要通过文件、Socket 或其他机制交换数据；
使用 DPI 后，SystemVerilog 可以直接调用 C 函数。

*/



// ★★★ Explain the simulation phases of SystemVerilog verification?   仿真阶段

/*
1.1 主要事件区域
SystemVerilog 标准定义了多个事件区域。学习验证时，先掌握以下几个最重要的区域即可。完整的事件调度机制见 IEEE 1800 标准。

事件区域	主要作用	常见关联
Preponed	在当前时间槽的活动开始前采样信号	SVA 属性采样
Active	执行普通过程语句、计算阻塞赋值、计算非阻塞赋值的右值	always、initial
Inactive	执行通过 #0 延迟到此区域的事件	#0
NBA	更新非阻塞赋值的目标变量	<=
Observed	计算并评估并发断言属性	assert property
Reactive	执行断言的相关动作代码及程序块中的验证代码	program、断言动作块
Postponed	在当前时间槽末尾观察最终值	$strobe、$monitor 的输出调度
*/

/*
    事件区域	对应代码	在第一个上升沿 t=5 的行为
    Preponed	assert property 的采样	采样到 q=0

    Active	$display、q <= ~q 的右值计算	打印 q=0，计算出新值 1
    Inactive	#0 后的 $display	仍然打印 q=0
    NBA	q <= ~q 的更新	q 更新为 1

    Observed	q == 0 的断言求值	使用采样值 0，断言通过

    Reactive	program 过程、断言失败动作块	program 看到更新后的 q=1；断言失败动作块此时不执行
    Postponed	$strobe、$monitor 的输出	观察到 q=1

*/

/*
    reactive 阶段的 program  &  clocking 块 都是为了避免 仿真和DUT 之间的竞争
*/
clocking cb @(posedge clk);
    default input #1step output #0;

    output wr_en, wr_data;
    input  q;
endclocking



module tb;
    bit clk = 0;
    bit q   = 0;

    // 产生周期为 10 个时间单位的时钟
    always #5 clk = ~clk;

    // Active、Inactive、NBA、Postponed
    always @(posedge clk) begin
        $display("Active:    t=%0t q=%0b", $time, q);

        q <= ~q;

        #0;
        $display("Inactive:  t=%0t q=%0b", $time, q);

        $strobe("Postponed: t=%0t q=%0b", $time, q);   // strobe会在postponed 阶段打印, 输出(同步事件)时间槽作用之后的值
    end

    // Preponed 采样，Observed 求值，Reactive 执行动作块
    ap_q: assert property (@(posedge clk) q == 0)
        else $display("Reactive assertion failed: t=%0t q=%0b",
                      $time, q);

    initial begin
        $monitor("$monitor:  t=%0t q=%0b", $time, q);   // monitor自动打印 也在 postponed 阶段, 输出后值
        #22;
        $finish;
    end

    // program 中的过程代码在 Reactive 区域执行
    p_check u_check(clk, q);

endmodule


program p_check(input logic clk, input logic q);
    initial begin
        @(posedge clk);
        $display("Reactive program: t=%0t q=%0b", $time, q);
    end
endprogram



// What is the difference between the clocking block and modport?
// 这两个都可以定义到interface里面, 来定义接口的仿真驱动 时序 & 方向  


// What is scope randomization?     
// 对当前作用域中的变量进行随机化，常见方式是使用系统任务 std::randomize()
module tb;
    int a, b;

    initial begin
        if (std::randomize(a, b) with {
            a inside {[1:10]};
            b == a * 2;
        }) begin
            $display("a=%0d, b=%0d", a, b);
        end
        else begin
            $display("Randomization failed");
        end
    end
endmodule

// What are automatic variables?
// automatic可以让这个task并行调用, 互相不干扰

task automatic count();
    int i = 0;
    i++;
    $display("i = %0d", i);
endtask

initial begin
    count();
    count();
    count();
end


// Explain the difference between fork-join, fork-join_none, and fork- join_any?
/*
    语法	父进程何时继续执行？	子进程是否自动终止？
    fork...join	所有子进程完成后	不会自动终止其他进程
    fork...join_any	任意一个子进程完成后	不会自动终止其他进程
    fork...join_none	不等待子进程完成，立即继续	不会自动终止子进程
*/


// ★★★ What is constraint solve-before?   使约束限制具有先后顺序

class Packet;
    rand bit [1:0] mode;
    rand bit [7:0] len;

    constraint c {
        mode inside {[0:2]};
        if (mode == 0)
            len == 10;
        else
            len == 20;

        solve mode before len; //
    }
endclass


// What are illegal bins? Is it good to use it and why?
// 一般来说不用illegal bins, 而是用assert来检查 是否出现 不符合预期的行为




// What is a package?   package  多个module 共享声明和定义, 通过 import 引入
package cpu_pkg;
    parameter int DATA_WIDTH = 32;

    typedef enum logic [1:0] {
        ADD,
        SUB,
        LOAD,
        STORE
    } opcode_t;

    function automatic int add(int a, int b);
        return a + b;
    endfunction
endpackage

module cpu;
    import cpu_pkg::*;   // import 之后就可以使用这个package里面的 所有定义

    opcode_t opcode;
    logic [DATA_WIDTH-1:0] data;

    initial begin
        opcode = ADD;
        $display("%0d", add(3, 4));
    end
endmodule


// Explain pass by value and pass by ref?
task automatic change(input int x);
    x = 100;
endtask

module tb;
    int a = 10;

    initial begin
        change(a);
        $display("a = %0d", a);  // 10
    end
endmodule


task automatic change(ref int x);   // 传递引用 ref
    x = 100;
endtask

module tb;
    int a = 10;

    initial begin
        change(a);
        $display("a = %0d", a);  // 100
    end
endmodule



// What is the difference between associative and dynamic array?  关联数组  动态数组

// 关联数组
module tb;
    int arr[int];   // associative array

    initial begin
        arr[10]  = 100;
        arr[100] = 200;
        arr[1000] = 300;

        $display("%0d", arr[100]); // 200
        $display("%0d", arr.num()); // 3
    end
endmodule


// What is the type of SystemVerilog assertions? 
// immediate assertion & concurrent assertion     即时断言  并发断言
/*
    Concurrent Assertion 中常见的三种使用方式：
    类型	关键字	用途
    Assertion	assert property	检查设计行为是否满足要求
    Assumption	assume property	约束环境行为，常用于形式验证
    Coverage	cover property	检查指定时序场景是否发生

    例如：
    assert property (@(posedge clk) req |-> ##1 ack);
    cover property  (@(posedge clk) req ##1 ack);
*/