`timescale 1ns/1ps
module tb_volume_range;
    reg clk=0,rst=1,fire=0,eof=0;
    always #5 clk=~clk;
    reg [3:0] masks=0;
    wire frame_valid,frame_good;
    wire [127:0] volumes;
    integer count=0;
    mask_volume_estimator dut(.clk(clk),.rst(rst),.pixel_fire(fire),.pixel_eof(eof),
        .masks(masks),.frame_valid(frame_valid),.frame_good(frame_good),.volumes_x100(volumes));
    always @(posedge clk)if(!rst && frame_valid)begin
        if(!frame_good)$fatal(1,"valid full-sized frame rejected");
        for(int c=0;c<4;c++)begin
            case(count)
                0:if(volumes[c*32+:32]!=32'd1317679360)$fatal(1,"full frame overflow/scale error %0d",volumes[c*32+:32]);
                1:if(volumes[c*32+:32]!=79)$fatal(1,"last pixel omitted");
                2:if(volumes[c*32+:32]!=0)$fatal(1,"empty frame retained data");
                default:$fatal(1,"extra frame result");
            endcase
        end
        count++;
    end
    initial begin
        repeat(4)@(negedge clk);rst=0;
        for(int f=0;f<3;f++)begin
            for(int i=0;i<65536;i++)begin
                @(negedge clk);fire=1;eof=i==65535;
                masks=(f==0 || (f==1 && i==65535))?15:0;
            end
        end
        @(negedge clk);fire=0;eof=0;
        wait(count==3);@(negedge clk);
        $display("[PASS] tb_volume_range: 256x256 full mask=1317679360 (x100), final pixel=79, empty=0, no overflow");$finish;
    end
    initial begin #3000000;$fatal(1,"range test timeout");end
endmodule
