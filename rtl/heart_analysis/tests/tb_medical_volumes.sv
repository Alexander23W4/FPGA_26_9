`timescale 1ns/1ps
// Independent pixel geometry oracle plus the REAL top_threshold_demo AXI path.
module tb_medical_volumes;
    reg clk=0,rst=1,in_valid=0,out_ready=0;
    always #6.25 clk=~clk;
    reg [3:0] masks=0;
    reg eof=0;
    wire in_ready,out_valid,out_eof;
    wire [127:0] volumes;
    wire [31:0] seq,status;
    reg [3:0] pixels[0:2559];
    reg [127:0] golden[0:19];
    reg [31:0] araddr=0;
    reg arvalid=0,rready=0;
    wire arready,rvalid;
    wire [31:0] rdata;
    wire [1:0] rresp;
    integer cycles=0,emitted=0;
    medical_accel_top #(.FRAME_W(16),.FRAME_H(8)) dut(
        .clk(clk),.rst(rst),.in_data(8'h63),.in_eof(eof),.in_valid(in_valid),.in_ready(in_ready),
        .in_LA_ctr(1'b0),.in_RA_ctr(1'b0),.in_LV_ctr(1'b0),.in_RV_ctr(1'b0),
        .in_LA_mask(masks[0]),.in_RA_mask(masks[1]),.in_LV_mask(masks[2]),.in_RV_mask(masks[3]),
        .out_valid(out_valid),.out_ready(out_ready),.out_eof(out_eof),
        .VOLUME_LA(volumes[31:0]),.VOLUME_RA(volumes[63:32]),
        .VOLUME_LV(volumes[95:64]),.VOLUME_RV(volumes[127:96]),
        .VOLUME_SEQ(seq),.VOLUME_STATUS(status));
    top_threshold_demo register_path(.clk(clk),.rst_n(!rst),
        .VOLUME_LA(volumes[31:0]),.VOLUME_RA(volumes[63:32]),
        .VOLUME_LV(volumes[95:64]),.VOLUME_RV(volumes[127:96]),.VOLUME_SEQ(seq),.VOLUME_STATUS(status),
        .s_axi_araddr(araddr),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
        .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready),
        .return_interval_cycles(32'd0),.return_stall_cycles(32'd0),.return_interval_seq(32'd0),
        .back_status(3'd0),.back_frame_mode(8'd0));
    always @(negedge clk)out_ready=!rst&&cycles%137<95&&$urandom_range(0,3)!=0;
    always @(posedge clk)begin
        cycles++;
        if(!rst&&out_valid&&out_ready)emitted++;
    end
    task automatic read_metric(input integer index,input [31:0] expected);
        @(negedge clk);araddr=index*4;arvalid=1;
        do @(posedge clk);while(!arready);
        @(negedge clk);arvalid=0;
        repeat(3)begin
            @(posedge clk);#1;
            if(!rvalid||rresp!==0||rdata!==expected)$fatal(1,"volume AXI %h got=%d expected=%d",index,rdata,expected);
        end
        @(negedge clk);rready=1;@(negedge clk);rready=0;
    endtask
    initial begin
        $readmemh("mask_volume_input.hex",pixels);
        $readmemh("mask_volume_expected.hex",golden);
        repeat(4)@(negedge clk);rst=0;
        if(seq!==0||volumes!=={4{32'hffffffff}})$fatal(1,"invalid reset snapshot");
        for(int f=0;f<20;f++)begin
            for(int i=0;i<128;i++)begin
                @(negedge clk);masks=pixels[f*128+i];eof=i==127;in_valid=1;
                do @(posedge clk);while(!in_ready);
            end
            @(negedge clk);in_valid=0;eof=0;
            wait(seq==f+1);@(negedge clk);
            if(!status[0])$fatal(1,"good frame flagged malformed");
            for(int c=0;c<4;c++)begin
                reg [31:0] reference;
                integer delta;
                reference=golden[f][c*32+:32];
                delta=$signed(volumes[c*32+:32])-$signed(reference);
                if(reference==0)begin
                    if(volumes[c*32+:32]!==32'hffffffff||status[c+1])$fatal(1,"empty chamber not invalid");
                end else if(delta>1||delta< -1||!status[c+1])$fatal(1,"per-frame geometry mismatch");
                read_metric('h10+c,volumes[c*32+:32]);
            end
            read_metric('h14,f+1);read_metric('h15,status);read_metric('h16,32'h564f4c31);
        end
        // A short frame publishes an INVALID snapshot rather than a partial volume.
        @(negedge clk);in_valid=1;eof=1;masks=15;
        do @(posedge clk);while(!in_ready);
        @(negedge clk);in_valid=0;eof=0;
        wait(seq==21);@(negedge clk);
        if(status!==0||volumes!=={4{32'hffffffff}})$fatal(1,"short frame volume accepted");
        wait(emitted==2561);
        $display("[PASS] tb_medical_volumes: 20 independent four-chamber frame volumes, AXI readback/sequence/ABI, backpressure, empty/short frames");
        $finish;
    end
    initial begin #1000000;$fatal(1,"volume publication timeout");end
endmodule
