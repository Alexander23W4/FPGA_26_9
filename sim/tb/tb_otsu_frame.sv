`timescale 1ns/1ps
module tb_otsu_frame;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    reg [31:0] awaddr=0,wdata=0;
    reg awvalid=0,wvalid=0;
    wire awready,wready,bvalid;
    wire [1:0] bresp;
    reg [7:0] data=0;
    reg valid=0,last=0,down_ready=0;
    wire ready,out_valid,out_last,out_mask,out_contour;
    wire [7:0] out_data,threshold;
    wire auto_mode;
    reg [7:0] pixels[0:8*65536-1], expected[0:7];
    integer cycle=0,frame=0,index=0,source_frame,expected_th,mask_count=0;
    integer input_frame,input_index;
    reg expected_mask,was_stalled=0;
    reg [10:0] held_payload;
    top_threshold_demo dut(
        .clk(clk),.rst_n(rst_n),
        .s_axi_awaddr(awaddr),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
        .s_axi_wdata(wdata),.s_axi_wstrb(4'hf),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
        .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(1'b1),
        .s_axi_araddr(32'd0),.s_axi_arvalid(1'b0),.s_axi_rready(1'b1),
        .s_axis_tdata(data),.s_axis_tvalid(valid),.s_axis_tready(ready),.s_axis_tlast(last),
        .m_axis_tdata(out_data),.m_axis_tvalid(out_valid),.m_axis_tready(down_ready),
        .m_axis_tlast(out_last),.m_axis_tmask(out_mask),.m_axis_tcontour(out_contour),
        .threshold_out(threshold),.auto_mode_out(auto_mode),
        .back_frame_mode(8'd0),.back_status(3'd0));

    task axi_write(input [31:0] address,input [31:0] value);
        begin
            @(negedge clk);awaddr=address;wdata=value;awvalid=1;wvalid=1;
            @(posedge clk);while(!(awready&&wready))@(posedge clk);
            @(negedge clk);awvalid=0;wvalid=0;
            wait(bvalid);if(bresp!=0)$fatal(1,"[FAIL] AXI write");
            @(negedge clk);
        end
    endtask

    // Deterministic stalls and bubbles, including held output EOF.
    always @(negedge clk) begin
        cycle=cycle+1;
        down_ready=(cycle%11>=3)&&!(out_last&&cycle%17<9);
    end
    always @(posedge clk) if(rst_n)begin
        if(was_stalled&&(!out_valid||{out_data,out_mask,out_contour,out_last}!==held_payload))
            $fatal(1,"[FAIL] output changed under backpressure");
        was_stalled=out_valid&&!down_ready;
        held_payload={out_data,out_mask,out_contour,out_last};
        if(out_valid&&down_ready)begin
            source_frame=frame<8?frame:0;
            expected_th=frame<8?expected[frame]:(frame<10?100:expected[0]);
            expected_mask=frame==8||frame==9
                ?pixels[source_frame*65536+index]>=expected_th
                :pixels[source_frame*65536+index]>expected_th;
            if(out_data!==pixels[source_frame*65536+index]||out_mask!==expected_mask||
               out_last!==(index==65535)||threshold!==expected_th||auto_mode!==(frame!=8&&frame!=9))
                $fatal(1,"[FAIL] frame=%0d pixel=%0d data=%0d mask=%0d expected_mask=%0d th=%0d expected_th=%0d auto=%b",
                    frame,index,out_data,out_mask,expected_mask,threshold,expected_th,auto_mode);
            if(out_contour&&!out_mask)$fatal(1,"[FAIL] contour outside mask");
            if(out_mask)mask_count=mask_count+1;
            if(out_last)begin
                $display("CASE frame %0d: threshold=%0d foreground=%0d",frame,threshold,mask_count);
                frame=frame+1;index=0;mask_count=0;
            end else index=index+1;
        end
    end

    task send_frame(input integer source,input bit change_config);
        integer i;
        begin
            for(i=0;i<65536;i=i+1)begin
                if(change_config&&i==32768)begin
                    @(negedge clk);valid=0;last=0;
                    axi_write(32'h80,200);axi_write(32'h04,0);
                end
                @(negedge clk);data=pixels[source*65536+i];valid=1;last=i==65535;
                @(posedge clk);while(!ready)@(posedge clk);
                if(i%997==0)begin @(negedge clk);valid=0;last=0;end
            end
            @(negedge clk);valid=0;last=0;
        end
    endtask

    initial begin
        $readmemh("pixels.mem",pixels);$readmemh("thresholds.mem",expected);
        repeat(5)@(negedge clk);rst_n=1;
        for(input_frame=0;input_frame<8;input_frame=input_frame+1)send_frame(input_frame,0);
        wait(frame==8);
        axi_write(32'h80,100);axi_write(32'h04,1);
        send_frame(0,0);wait(frame==9);
        send_frame(0,1);wait(frame==10);
        send_frame(0,0);wait(frame==11);
        repeat(20)@(negedge clk);
        if(out_valid)$fatal(1,"[FAIL] duplicate output after EOF");
        $display("[PASS] current-frame thresholds, 11 frames, stable mode, manual equality, full replay/backpressure");
        $finish;
    end
    initial begin #100000000;$fatal(1,"[FAIL] frame timeout");end
endmodule
