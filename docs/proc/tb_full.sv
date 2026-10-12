
`timescale 1ps/1ps

interface axi_lite(
    logic [31:0] awaddr;
    logic        awvalid;
    logic        awready;

    logic [31:0] wdata;
    logic [3:0]  wstrb;
    logic        wvalid;
    logic        wready;

    logic [1:0]  bresp;
    logic        bvalid;
    logic        bready;

    logic [31:0] araddr;
    logic        arvalid;
    logic        arready;

    logic [31:0] rdata;
    logic [1:0]  rresp;
    logic        rvalid;
    logic        rready;
);
    modport master (
        output awaddr,
        output awvalid,
        input  awready,

        output wdata,
        output wstrb,
        output wvalid,
        input  wready,

        input  bresp,
        input  bvalid,
        output bready,

        output araddr,
        output arvalid,
        input  arready,

        input  rdata,
        input  rresp,
        input  rvalid,
        output rready
    );

endinterface


interface axi_stream(

    logic [63:0] tdata,
    logic        tvalid,
    logic        tready,    
    logic        tlast,
    logic [7:0]  tkeep,
    logic        tuser
);
    modport master (
        output tdata,
        output tvalid,
        input  tready,
        output tlast,
        output tkeep,
        output tuser
    );


endinterface


module tb_full;

// 配置时钟信号
    timeunit 1ps;
    timeprecision 1ps;

    logic clk;
    logic rst;

    always #5 clk = ~clk;     // 生成clk, 这里我让仿真的clk的周期尽可能的小

    logic pclk;
    logic pclk_x5;

    always #5 pclk = ~pclk;     
    always #1 pclk_x5 = ~pclk_x5;     


    localparam int  FRAME_PIXELS = 256 * 256;

    axi_lite.master al();
    axi_stream.master as();

    top1 u_top(
        .clk(clk),
        .rst(rst),
        .pclk(pclk),
        .pclk_x5(pclk_x5),

        .s_axis_data(as.tdata),
        .s_axis_valid(as.tvalid),
        .s_axis_ready(as.tready),
        .s_axis_last(as.tlast),
        .s_axis_keep(as.tkeep),
        .s_axis_user(as.tuser),

        .awaddr(al.awaddr),  //
        .awvalid(al.awvalid), //
        .awready(al.awready),  //-
        .wdata(al.wdata),   //
        .wstrb(al.wstrb),
        .wvalid(al.wvalid),  //
        .wready(al.wready),  //-
        .bresp(al.bresp), 
        .bvalid(al.bvalid), //-
        .bready(al.bready), //

        .araddr(al.araddr),
        .arvalid(al.arvalid),
        .arready(al.arready),
        .rdata(al.rdata),
        .rresp(al.rresp),
        .rvalid(al.rvalid),
        .rready(al.rready),

    )

// ★★: [Learn] 仿真协议输入的sv-tb实现
    task automatic set_mode(
        input [7:0] mode,
        input [31:0] value
    );
        bit aw_done;
        bit w_done;

        @(posedge clk) begin
            al.awaddr = mode;
            al.awvalid = 1;
            al.wvalid = 1;
            al.wdata = value;

            while(!aw_done || !w_done) begin
                if(al.awready) aw_done = 1; al.awvalid = 0;
                if(al_wready) w_done = 1; al.wvalid = 0;
            end
        end

        @(posedge clk) begin
            while(!al.bvalid);

            al.bready = 1;
            #10;
            al.bready = 0;
        end

    endtask

    task automatic set_pixel(
        input int data
    );

    endtask
    /*
    通过axi-stream发送一帧 256*256的图像数据, 图像采用固定图像
    固定图像: 每一行灰度值为 0, 1, 2,... 255 (第一行) 0, 2, 4, ...254, 0, 2...(第二行) 0, 3, 6...(第三行)
    
    */
    task automatic send_frame(
        input int frame_num
    );
    
    endtask

    task automatic read_mode(
        output int mode
    );

    endtask


endmodule

