
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



