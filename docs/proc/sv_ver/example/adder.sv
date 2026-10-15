
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

    always_ff @(posedge clk) begin
        if (reset) begin
            c <= '0;
        end
        else if (valid) begin
            c <= a + b;
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

    constraint a_range {
        unique a;
    }

    constraint b_range {
        unique b;
        b inside {[8'h20:$]};
    }

endclass


// generator 产生一个随机transaction激励, 通过mailbox传给driver

class generator;
    packet pkt;
    mailbox mbx;

    event gen_end;   // ★
    int repeat_cnt;    //

    function new(mailbox mbx);
        this.mbx = mbx;
    endfunction

    function gen;
        pkt = new();
        repeat(repeat_cnt) begin
            if(pkt.randomize()) begin
                mbx.put(pkt);
            end else begin
                $fatal("error randomization");
            end
        end
        ->gen_end;  // 
    endfunction

endclass



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