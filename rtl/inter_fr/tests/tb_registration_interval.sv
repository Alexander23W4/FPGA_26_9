`timescale 1ns/1ps
// Full-size worst case: every candidate has the same nonzero SAD, so none can
// be pruned. Receive/output overlap is included in the measured frame period.
module tb_registration_interval;
    localparam N=65536;
    reg clk=0,rst=1,valid=0,eof=0;
    always #6.25 clk=~clk;
    reg [7:0] data=0;
    wire ready,ov,oe,done,error;
    wire [7:0] od;
    wire signed [15:0] dx,dy;
    wire [31:0] sad;
    integer cycles=0,last_result=0,result_count=0,output_frame=0,output_index=0;
    registration_top dut(.clk(clk),.rst(rst),.in_data(data),.in_valid(valid),.in_eof(eof),.in_ready(ready),
        .out_data(od),.out_valid(ov),.out_eof(oe),.out_ready(1'b1),
        .reg_dx(dx),.reg_dy(dy),.reg_sad(sad),.reg_valid(),.reg_done(done),.frame_count(),.frame_error(error));
    always @(posedge clk)begin
        cycles++;
        if(!rst)begin
            if(ov)begin
                if(od!==output_frame[7:0] || oe!==(output_index==N-1))$fatal(1,"full-size replay pixel/EOF");
                if(oe)begin output_frame++;output_index=0;end
                else output_index++;
            end
            if(done)begin
                if(dx!=0||dy!=0||sad!=2304||error)$fatal(1,"full-size SAD or frame error");
                if(result_count!=0)begin
                    if(cycles-last_result>733000)$fatal(1,"receive/output did not overlap");
                    $display("DEFAULT_FRAME_INTERVAL clocks=%0d period_ms_at_80MHz=%0f",cycles-last_result,(cycles-last_result)/80000.0);
                end
                result_count++;last_result=cycles;
            end
        end
    end
    initial begin
        repeat(4)@(negedge clk);rst=0;
        for(integer f=0;f<3;f++)begin
            for(integer i=0;i<N;i++)begin
                @(negedge clk);data=f;valid=1;eof=(i==N-1);
                do @(posedge clk);while(!ready);
            end
            @(negedge clk);valid=0;eof=0;
        end
        wait(output_frame==3);@(negedge clk);
        if(result_count!=2)$fatal(1,"result count");
        $display("[PASS] tb_registration_interval: 256x256, full 289-candidate search, receive/output overlap");$finish;
    end
    initial begin #40000000;$fatal(1,"full-size registration timeout");end
endmodule
