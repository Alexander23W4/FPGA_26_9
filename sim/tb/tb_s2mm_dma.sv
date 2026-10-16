`timescale 1ns/1ps
// Official AXI DMA model: pixel stream -> 64-bit memory with bounded stalls.
module tb_s2mm_dma;
    localparam [31:0] BASE=32'h20010000;
    reg clk=0,resetn=0;
    always #10 clk=~clk;
    reg [9:0] awaddr=0,araddr=0;
    reg [31:0] wdata=0;
    reg awvalid=0,wvalid=0,arvalid=0;
    wire awready,wready,bvalid,arready,rvalid;
    wire [1:0] bresp,rresp;
    wire [31:0] rdata;
    reg [31:0] pixel=0;
    reg valid=0,last=0;
    wire ready;
    wire [31:0] ma;
    wire [7:0] mlen;
    wire [2:0] msize;
    wire [1:0] mburst;
    wire mav,mwv,mwl,mbr;
    wire [63:0] md;
    wire [7:0] ms;
    reg mbv=0;
    wire mar=resetn&&!active&&!mbv&&(cycles%17<12);
    wire mwr=resetn&&active&&(cycles%11<8);
    return_dma dut (
        .s_axi_lite_aclk(clk),.m_axi_s2mm_aclk(clk),.axi_resetn(resetn),
        .s_axi_lite_awaddr(awaddr),.s_axi_lite_awvalid(awvalid),.s_axi_lite_awready(awready),
        .s_axi_lite_wdata(wdata),.s_axi_lite_wvalid(wvalid),.s_axi_lite_wready(wready),
        .s_axi_lite_bvalid(bvalid),.s_axi_lite_bready(1'b1),.s_axi_lite_bresp(bresp),
        .s_axi_lite_araddr(araddr),.s_axi_lite_arvalid(arvalid),.s_axi_lite_arready(arready),
        .s_axi_lite_rdata(rdata),.s_axi_lite_rvalid(rvalid),.s_axi_lite_rready(1'b1),.s_axi_lite_rresp(rresp),
        .s_axis_s2mm_tdata(pixel),.s_axis_s2mm_tkeep(4'hf),.s_axis_s2mm_tvalid(valid),
        .s_axis_s2mm_tready(ready),.s_axis_s2mm_tlast(last),
        .m_axi_s2mm_awaddr(ma),.m_axi_s2mm_awlen(mlen),.m_axi_s2mm_awsize(msize),
        .m_axi_s2mm_awburst(mburst),.m_axi_s2mm_awvalid(mav),.m_axi_s2mm_awready(mar),
        .m_axi_s2mm_awprot(),.m_axi_s2mm_awcache(),
        .m_axi_s2mm_wdata(md),.m_axi_s2mm_wstrb(ms),.m_axi_s2mm_wlast(mwl),
        .m_axi_s2mm_wvalid(mwv),.m_axi_s2mm_wready(mwr),
        .m_axi_s2mm_bresp(2'b00),.m_axi_s2mm_bvalid(mbv),.m_axi_s2mm_bready(mbr),
        .s2mm_prmry_reset_out_n(),.s2mm_introut(),.axi_dma_tstvec()
    );
    reg [7:0] memory[0:262143];
    bit seen[0:262143];
    reg active=0;
    reg [31:0] address;
    integer beats=0,step_bytes=0,bytes_written=0,cycles=0,bursts=0,index;
    always @(posedge clk) begin
        cycles<=cycles+1;
        if(!resetn) begin active<=0;mbv<=0;end
        else begin
            if(mbv&&mbr)mbv<=0;
            if(mav&&mar)begin
                if(ma!==BASE+bytes_written||mburst!==2'b01||msize>3)
                    $fatal(1,"[FAIL] memory address/burst mismatch addr=%h written=%0d size=%0d",ma,bytes_written,msize);
                active<=1;address<=ma;beats<=mlen+1;step_bytes<=1<<msize;bursts<=bursts+1;
            end
            if(mwv&&mwr)begin
                if(mwl!==(beats==1))$fatal(1,"[FAIL] AXI WLAST mismatch");
                for(integer lane=0;lane<8;lane=lane+1)if(ms[lane])begin
                    index=(address&32'hfffffff8)+lane-BASE;
                    if(index<0||index>=262144||seen[index])$fatal(1,"[FAIL] overwritten/out-of-range byte %0d",index);
                    memory[index]=md[lane*8+:8];seen[index]=1;bytes_written=bytes_written+1;
                end
                address<=address+step_bytes;beats<=beats-1;
                if(beats==1)begin active<=0;mbv<=1;end
            end
        end
    end
    task automatic write_reg(input [9:0] a,input [31:0] d);
        @(negedge clk);awaddr=a;wdata=d;awvalid=1;wvalid=1;
        fork
            begin do @(posedge clk);while(!awready);@(negedge clk);awvalid=0;end
            begin do @(posedge clk);while(!wready);@(negedge clk);wvalid=0;end
        join
        do @(posedge clk);while(!bvalid);
        if(bresp!==0)$fatal(1,"[FAIL] control write error");
        @(negedge clk);
    endtask
    task automatic read_reg(input [9:0] a,output [31:0] d);
        @(negedge clk);araddr=a;arvalid=1;
        do @(posedge clk);while(!arready);
        @(negedge clk);arvalid=0;
        do @(posedge clk);while(!rvalid);
        if(rresp!==0)$fatal(1,"[FAIL] control read error");
        d=rdata;@(negedge clk);
    endtask
    function automatic [31:0] pattern(input integer n);
        pattern={8'h04,n[7:0],n[15:8],8'ha5};
    endfunction
    task automatic run_frame(input integer count);
        reg [31:0] status,length,expected;
        integer polls;
        @(negedge clk);bytes_written=0;bursts=0;
        for(integer i=0;i<262144;i=i+1)begin memory[i]=8'hcc;seen[i]=0;end
        // Same register order and values as drv_s2mm.c.
        write_reg('h30,4);
        status=4;polls=0;
        while(status&4)begin read_reg('h30,status);if(polls++>1000)$fatal(1,"[FAIL] reset timeout");end
        write_reg('h34,'h7000);write_reg('h30,1);write_reg('h48,BASE);write_reg('h58,262144);
        for(integer i=0;i<count;i=i+1)begin
            @(negedge clk);pixel=pattern(i);valid=1;last=(i==count-1);
            do @(posedge clk);while(!ready);
            @(negedge clk);valid=0;last=0;
            if(i%31==0)repeat(3)@(negedge clk);
        end
        status=0;polls=0;
        while((status&32'h1002)!=32'h1002)begin
            read_reg('h34,status);
            if(status&32'h770)$fatal(1,"[FAIL] DMA status error %h",status);
            if(polls++>10000)$fatal(1,"[FAIL] completion timeout %h",status);
        end
        read_reg('h58,length);
        if(length!=count*4||bytes_written!=count*4)$fatal(1,"[FAIL] received length %0d / %0d",length,bytes_written);
        for(integer i=0;i<count;i=i+1)begin
            expected=pattern(i);
            for(integer lane=0;lane<4;lane=lane+1)
                if(!seen[i*4+lane]||memory[i*4+lane]!==expected[lane*8+:8])
                    $fatal(1,"[FAIL] incorrect pixel %0d byte %0d",i,lane);
        end
        if(count<65536&&seen[count*4])$fatal(1,"[FAIL] short packet exceeded received length");
        $display("[PASS] AXI_DMA pixels=%0d bytes=%0d bursts=%0d; byte-exact BGRmode under stalls",count,length,bursts);
    endtask
    initial begin
        repeat(20)@(negedge clk);resetn=1;repeat(20)@(negedge clk);
        run_frame(65536);run_frame(1023);
        $display("S2MM_DMA_OK: complete 256KiB frame, actual short length, 32-to-64 packing, independent AW/W stalls");
        $finish;
    end
    initial begin #50000000;$fatal(1,"[FAIL] test timeout");end
endmodule
