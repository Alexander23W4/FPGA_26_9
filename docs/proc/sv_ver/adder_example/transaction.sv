
// transaction  用来在仿真环境中传递数据, 定义随机约束
class packet;
    rand bit [7:0] a;
    randc bit [7:0] b;
    bit [8:0] c;
    bit larger_a;

    constraint a_range {
        unique a;
    }

    constraint b_range {
        unique b;
        b inside {[8'h20:$]};
    }

    function void display(string name);    // ★: 这只是一个仿真的流程输出, 并不属于trace, 没有监视DUT的内部状态
        $display("-------------------------");
        $display("- %s ",name);
        $display("-------------------------");
        $display("- a = %0d, b = %0d",a,b);
        $display("- c = %0d",c);
        $display("-------------------------");
    endfunction
endclass


/*
    // 这个adder并不是状态机, DUT内部没有reg存储任何状态. 
    // ★: 如果是状态机DUT, 则可以通过输出内部状态输出更丰富的trace

    可以使用下面这个方法, 用bind在仿真顶层连接checker[module], checker这个module可以专门输出trace

    module dut_checker (
        input logic clk,
        input logic larger_a
    );
        always @(posedge clk) begin
            $display("[TRACE] time=%0t larger_a=%0b",
                    $time, larger_a);
        end
    endmodule

    bind dut dut_checker checker_inst (
        .clk      (clk),
        .larger_a (larger_a)
    ); 
*/