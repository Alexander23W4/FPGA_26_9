
/*
--> Monitor
Samples the interface signals and converts the signal level activity to the transaction level.
Send the sampled transaction to Scoreboard via Mailbox.
*/

// DUT: 
module adder (
    input  logic       clk,
    input  logic       reset,
    input  logic [7:0] a,
    input  logic [7:0] b,
    input  logic       valid,
    output logic [8:0] c
);
    reg larger_a;

    always_ff @(posedge clk) begin
        if (reset) begin
            c <= '0;
            larger_a <= 1'b0;
        end
        else if (valid) begin
            c <= a + b;
        end

        if(a > b) begin
            larger_a <= 1'b1;
        end else begin
            larger_a <= 1'b0;
        end
    end

endmodule


// interface   用来连接DUT
interface intf;
    logic [7:0] a;
    logic [7:0] b;
    logic [8:0] c;
    // logic reset;    // ★  这里interface 不需要 reset & clk, 直接从仿真top连接
    // logic clk;
    logic valid;
endinterface


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


// generator 产生一个随机transaction激励, 通过mailbox传给driver

class generator;
    packet pkt;
    mailbox mbx;

    event gen_end;   // ★
    int repeat_cnt;    //

    function new(mailbox mbx);
        this.mbx = mbx;
    endfunction

    task gen;
        pkt = new();
        repeat(repeat_cnt) begin
            if(pkt.randomize()) begin
                mbx.put(pkt);
            end else begin
                $fatal("error randomization");
            end
        end
        ->gen_end;  // 
    endtask

endclass


// driver 从mailbox中获取激励值并用transaction接收, 按照接口时序驱动连接DUT的接口信号
class driver;
    int num_transac;   // driver计数
    mailbox mbx;
    virtual intf itf;
    packet pkt;

    function new(mailbox mbx, intf itf);
        this.mbx = mbx;
        this.itf = itf;
    endfunction

    task send;
        mbx.get(pkt);
        itf.valid = 0;
        itf.a = pkt.a;
        itf.b = pkt.b;

        @(negedge clk);
        itf.valid = 1;

        @(negedge clk);
        itf.valid = 0;

        num_transac++;
    endtask

endcalss


class monitor;
    virtual intf itf;
    mailbox mbx;

    function new(mailbox mbx, intf itf);
        this.mbx = mbx;
        this.itf = itf;
    endfunction

    // Sampling logic and sending the sampled transaction to the scoreboard.
    task samp;

    endtask

endclass




