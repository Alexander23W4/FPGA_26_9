`timescale 1ns/1ps
module tb_mask_volume;
    localparam W=16,H=8;
    reg clk=0,rst=1,fire=0,eof=0;
    always #5 clk=~clk;
    reg [3:0] masks=0;
    wire frame_valid,frame_good;
    wire [127:0] volumes;
    reg [128:0] expected[0:63];
    integer count=0,head=0,tail=0;
    mask_volume_estimator #(.FRAME_W(W),.FRAME_H(H)) dut(
        .clk(clk),.rst(rst),.pixel_fire(fire),.pixel_eof(eof),.masks(masks),
        .frame_valid(frame_valid),.frame_good(frame_good),.volumes_x100(volumes));
    reg [3:0] input_masks[0:2559];
    reg [127:0] golden[0:19];
    always @(posedge clk) if(!rst && frame_valid)begin
        reg [128:0] e;
        integer delta;
        if(head==tail)$fatal(1,"unexpected frame metric");
        e=expected[head];head++;
        if(frame_good!==e[128])$fatal(1,"bad frame marked valid (or valid frame discarded)");
        if(frame_good)for(int c=0;c<4;c++)begin
            delta=$signed(volumes[c*32+:32])-$signed(e[c*32+:32]);
            if(delta>1 || delta< -1)$fatal(1,"volume f=%0d c=%0d got=%0d expected=%0d",count,c,volumes[c*32+:32],e[c*32+:32]);
        end
        count++;
    end
    task automatic send(input integer f,n,input bit gaps);
        expected[tail]={(n==W*H),golden[f]};tail++;
        for(int i=0;i<n;i++)begin
            @(negedge clk);
            if(gaps && $urandom_range(0,4)==0)begin fire=0;repeat($urandom_range(1,3))@(negedge clk);end
            fire=1;eof=i==n-1;masks=input_masks[f*W*H+(i%(W*H))];
        end
        @(negedge clk);fire=0;eof=0;masks=4'bxxxx;
    endtask
    initial begin
        $readmemh("mask_volume_input.hex",input_masks);
        $readmemh("mask_volume_expected.hex",golden);
        repeat(4)@(negedge clk);rst=0;
        for(int f=0;f<20;f++)send(f,W*H,1);
        send(3,W*H-5,0);send(5,W*H+9,0);send(1,W*H,0);
        wait(count==23);@(negedge clk);
        if(head!=tail)$fatal(1,"lost results");
        $display("[PASS] tb_mask_volume: independent real-pi oracle, 4 masks, final pixel, holes, gaps, short/long frame recovery");$finish;
    end
    initial begin #200000;$fatal(1,"volume test timeout");end
endmodule
