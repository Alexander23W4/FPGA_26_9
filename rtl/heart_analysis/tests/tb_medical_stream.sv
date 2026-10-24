`timescale 1ns/1ps
module tb_medical_stream;
    reg clk=0, rst=1;
    always #6.25 clk=~clk;
    reg [16:0] offered=0;
    reg in_valid=0, out_ready=0;
    wire in_ready, out_valid;
    wire [16:0] received;
    wire [255:0] volumes;
    reg [16:0] expected[$];
    reg [16:0] held;
    reg stalled=0;
    integer accepted=0, emitted=0, cycles=0;
    reg random_ready=0;

    medical_accel_top dut(
        .clk(clk), .rst(rst), .in_data(offered[7:0]),
        .in_LA_ctr(offered[15]), .in_RA_ctr(offered[14]),
        .in_LV_ctr(offered[13]), .in_RV_ctr(offered[12]),
        .in_LA_mask(offered[11]), .in_RA_mask(offered[10]),
        .in_LV_mask(offered[9]), .in_RV_mask(offered[8]),
        .in_eof(offered[16]), .in_valid(in_valid), .in_ready(in_ready),
        .out_data(received[7:0]), .out_LA_ctr(received[15]),
        .out_RA_ctr(received[14]), .out_LV_ctr(received[13]),
        .out_RV_ctr(received[12]), .out_LA_mask(received[11]),
        .out_RA_mask(received[10]), .out_LV_mask(received[9]),
        .out_RV_mask(received[8]), .out_eof(received[16]),
        .out_valid(out_valid), .out_ready(out_ready),
        .EDV_LA(volumes[31:0]), .ESV_LA(volumes[63:32]),
        .EDV_RA(volumes[95:64]), .ESV_RA(volumes[127:96]),
        .EDV_LV(volumes[159:128]), .ESV_LV(volumes[191:160]),
        .EDV_RV(volumes[223:192]), .ESV_RV(volumes[255:224])
    );
    always @(negedge clk) if(random_ready) begin
        // Long stalls cross frame boundaries as well as individual pixels.
        out_ready = (cycles%101)<65 && $urandom_range(0,3)!=0;
    end
    always @(posedge clk) begin
        cycles++;
        if(rst) begin
            expected.delete(); accepted=0; emitted=0; stalled=0;
            if(in_ready || out_valid)$fatal(1,"handshake active during reset");
        end else begin
            if(stalled && (!out_valid || received!==held))
                $fatal(1,"payload/valid changed under backpressure");
            if(in_valid && in_ready) begin
                expected.push_back(offered); accepted++;
            end
            if(out_valid && out_ready) begin
                if(expected.size()==0)$fatal(1,"unexpected output");
                held=expected.pop_front();
                if(received!==held)$fatal(1,"lost/misaligned pixel or chamber flag");
                emitted++;
            end
            stalled=out_valid && !out_ready;
            held=received;
        end
    end
    task automatic send(input integer number, input integer frame_pixels,
                        input bit bubbles);
        for(int i=0;i<number;i++)begin
            @(negedge clk);
            if(bubbles && $urandom_range(0,3)==0) begin
                in_valid=0;repeat($urandom_range(1,3))@(negedge clk);
            end
            offered={((i%frame_pixels)==frame_pixels-1),16'((i*7919)^16'h935a)};
            in_valid=1;
            do @(posedge clk);while(!in_ready);
        end
        @(negedge clk);in_valid=0;
    endtask
    initial begin
        repeat(4)@(negedge clk);rst=0;
        // Reset with a buffered EOF and no downstream credit.
        offered=17'h1a55a;in_valid=1;
        @(posedge clk);@(negedge clk);in_valid=0;
        repeat(5)@(negedge clk);
        if(in_ready || !out_valid)$fatal(1,"full stage did not apply backpressure");
        rst=1;repeat(3)@(negedge clk);rst=0;
        random_ready=1;
        send(2048,256,1);
        @(negedge clk);random_ready=0;out_ready=1;
        wait(emitted==2048);@(negedge clk);
        if(accepted!=2048 || expected.size()!=0)$fatal(1,"random stream count mismatch");
        begin
            integer start_cycle;
            start_cycle=cycles;
            send(65536,65536,0);
            wait(emitted==2048+65536);@(negedge clk);
            if(cycles-start_cycle>65540)$fatal(1,"stream did not sustain one pixel/clock");
        end
        if(volumes!=={8{32'hffffffff}})$fatal(1,"unavailable volume was presented as a measurement");
        $display("[PASS] tb_medical_stream: pixels/8 flags/EOF, long stalls, reset flush, 65536 pixels at one/clock, unavailable results");
        $finish;
    end
    initial begin #5000000;$fatal(1,"medical stream timeout");end
endmodule
