module itv;
// What is the difference between an initial and final block of the systemverilog?
    initial begin
        
    end

    final begin
        
    end

endmodule

// Explain the simulation phases of SystemVerilog verification?   仿真阶段

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
