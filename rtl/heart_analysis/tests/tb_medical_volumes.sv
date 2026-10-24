`timescale 1ns/1ps
module tb_medical_volumes;
    localparam W=64,H=16,N=W*H;
    reg clk=0,rst=1,in_valid=0,out_ready=0;
    always #6.25 clk=~clk;
    reg [16:0] offered=0;
    wire [16:0] received;
    wire in_ready,out_valid;
    wire [127:0] ed,es;
    reg [127:0] golden[0:3];
    reg [16:0] expected[$];
    integer wave[0:22]='{6,8,10,12,12,10,8,6,4,4,6,8,10,11,11,9,7,5,3,3,5,7,9};
    integer cycles=0,updates=0,accepted=0,emitted=0;
    reg stalled=0;
    reg [16:0] held;
    reg [31:0] araddr=0;
    reg arvalid=0,rready=0;
    wire arready,rvalid;
    wire [31:0] rdata;
    wire [1:0] rresp;
    integer axi_pairs=0;
    medical_accel_top #(.FRAME_W(W),.FRAME_H(H)) dut(
        .clk(clk),.rst(rst),.in_data(offered[7:0]),.in_eof(offered[16]),
        .in_LA_ctr(offered[15]),.in_RA_ctr(offered[14]),.in_LV_ctr(offered[13]),.in_RV_ctr(offered[12]),
        .in_LA_mask(offered[11]),.in_RA_mask(offered[10]),.in_LV_mask(offered[9]),.in_RV_mask(offered[8]),
        .in_valid(in_valid),.in_ready(in_ready),.out_ready(out_ready),.out_valid(out_valid),
        .out_eof(received[16]),.out_data(received[7:0]),
        .out_LA_ctr(received[15]),.out_RA_ctr(received[14]),.out_LV_ctr(received[13]),.out_RV_ctr(received[12]),
        .out_LA_mask(received[11]),.out_RA_mask(received[10]),.out_LV_mask(received[9]),.out_RV_mask(received[8]),
        .EDV_LA(ed[31:0]),.EDV_RA(ed[63:32]),.EDV_LV(ed[95:64]),.EDV_RV(ed[127:96]),
        .ESV_LA(es[31:0]),.ESV_RA(es[63:32]),.ESV_LV(es[95:64]),.ESV_RV(es[127:96]));
    top_threshold_demo register_path(
        .clk(clk),.rst_n(!rst),
        .EDV_LA(ed[31:0]),.EDV_RA(ed[63:32]),.EDV_LV(ed[95:64]),.EDV_RV(ed[127:96]),
        .ESV_LA(es[31:0]),.ESV_RA(es[63:32]),.ESV_LV(es[95:64]),.ESV_RV(es[127:96]),
        .s_axi_awaddr(32'd0),.s_axi_awvalid(1'b0),.s_axi_wdata(32'd0),
        .s_axi_wstrb(4'd0),.s_axi_wvalid(1'b0),.s_axi_bready(1'b1),
        .s_axi_araddr(araddr),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
        .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready),
        .s_axis_tdata(8'd0),.s_axis_tvalid(1'b0),.s_axis_tlast(1'b0),.m_axis_tready(1'b1),
        .back_frame_mode(8'd0),.return_interval_cycles(32'd0),.return_stall_cycles(32'd0),
        .return_interval_seq(32'd0),.back_status(3'd0));
    task automatic read_metric(input integer word_id,input [31:0] expected_value);
        integer delta;
        @(negedge clk);araddr=word_id*4;arvalid=1;
        do @(posedge clk);while(!arready);
        @(negedge clk);arvalid=0;
        repeat(4)begin
            @(posedge clk);#1;delta=$signed(rdata)-$signed(expected_value);
            if(!rvalid || rresp!==0 || delta>1 || delta< -1)
                $fatal(1,"computed metric readback failed WORD=%h got=%0d expected=%0d",word_id,rdata,expected_value);
        end
        @(negedge clk);rready=1;
        @(negedge clk);rready=0;
    endtask
    initial begin
        wait(!rst);
        for(int pair=0;pair<2;pair++)begin
            wait(updates==pair+1);
            for(int r=0;r<8;r++)read_metric('h10+r,golden[pair*2+r%2][(r/2)*32+:32]);
            axi_pairs++;
        end
    end
    always @(negedge clk)out_ready=!rst && cycles%137<95 && $urandom_range(0,3)!=0;
    always @(posedge clk)begin
        cycles++;
        if(!rst)begin
            if(stalled && (!out_valid || received!==held))$fatal(1,"stream changed while stalled");
            if(in_valid && in_ready)begin expected.push_back(offered);accepted++;end
            if(out_valid && out_ready)begin
                reg [16:0] item;
                if(expected.size()==0)$fatal(1,"unexpected output");
                item=expected.pop_front();
                if(item!==received)$fatal(1,"stream content mismatch");
                emitted++;
            end
            stalled=out_valid && !out_ready;held=received;
            if(dut.result_updated)begin
                integer d;
                if(updates>=2)$fatal(1,"extra ED/ES pair");
                for(int c=0;c<4;c++)begin
                    d=$signed(ed[c*32+:32])-$signed(golden[updates*2][c*32+:32]);
                    if(d>1 || d< -1)$fatal(1,"ED mismatch pair=%0d chamber=%0d got=%0d",updates,c,ed[c*32+:32]);
                    d=$signed(es[c*32+:32])-$signed(golden[updates*2+1][c*32+:32]);
                    if(d>1 || d< -1)$fatal(1,"ES mismatch pair=%0d chamber=%0d got=%0d",updates,c,es[c*32+:32]);
                end
                $display("PAIR %0d ED_LV=%0d ES_LV=%0d ED_LA=%0d ES_LA=%0d",updates,ed[95:64],es[95:64],ed[31:0],es[31:0]);
                updates++;
            end
        end
    end
    initial begin
        $readmemh("medical_pair_expected.hex",golden);
        repeat(4)@(negedge clk);rst=0;
        for(int f=0;f<23;f++)begin
            for(int i=0;i<N;i++)begin
                integer x,y,width;
                reg [3:0] mask,ctr;
                @(negedge clk);
                if($urandom_range(0,9)==0)begin in_valid=0;repeat($urandom_range(1,3))@(negedge clk);end
                x=i%W;y=i/W;
                for(int c=0;c<4;c++)begin
                    case(c)
                        0:width=16-wave[f]/2;
                        1:width=4+wave[f]/2;
                        2:width=wave[f];
                        3:width=wave[f]+1;
                    endcase
                    mask[c]=x>=c*16 && x<c*16+width && y>=1 && y<=14;
                    ctr[c]=mask[c] && (x==c*16 || x==c*16+width-1 || y==1 || y==14);
                end
                offered={(i==N-1),ctr[0],ctr[1],ctr[2],ctr[3],mask[0],mask[1],mask[2],mask[3],8'(f*19+i)};
                in_valid=1;
                do @(posedge clk);while(!in_ready);
            end
            @(negedge clk);in_valid=0;
        end
        wait(emitted==23*N);repeat(12)@(negedge clk);
        wait(axi_pairs==2);
        if(updates!=2 || accepted!=23*N || expected.size()!=0)$fatal(1,"missing frame/result");
        $display("[PASS] tb_medical_volumes: actual 23-frame four-mask stream -> 2 real ED/ES pairs -> AXI reads of all 8 registers, payload/EOF preserved under backpressure");$finish;
    end
    initial begin #2000000;$fatal(1,"medical full algorithm timeout");end
endmodule
