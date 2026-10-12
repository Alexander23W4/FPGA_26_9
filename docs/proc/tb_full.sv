
/*

*/
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

// @(posedge clk);  代表驱动时钟, 类比verilator中的 top tick


// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-

// ★★: [Learn] 仿真协议输入的sv-tb实现
    task automatic set_mode(
        input [7:0] mode,
        input [31:0] value
    );
// bit: 标志位、握手状态  int: 计数器、整数运算、索引 (默认有符号)
        bit aw_done;
        bit w_done;

        aw_done = 0;
        w_done = 0;

        @(negedge clk);    // [Learn] tb的常用激励写法, 下降沿给激励, 上升沿读DUT反馈
        al.awaddr = mode;
        al.awvalid = 1;
        al.wdata = value;
        al.wstrb = 4'hF;
        al.wvalid = 1;
        al.bready = 0;

/*
@(posedge clk) 和 @(negedge clk) 是过程的执行控制点：执行到它们时，
    当前 begin-end 过程会暂停，直到对应的时钟沿到来，然后继续执行后面的语句。
*/

        while (!aw_done || !w_done) begin  
            @(posedge clk);
            if (al.awvalid && al.awready) aw_done = 1;   // 某个上升沿同时采到 awvalid和awready才行
            if (al.wvalid && al.wready) w_done = 1;

            @(negedge clk);
            if (aw_done) al.awvalid = 0;
            if (w_done) al.wvalid = 0;
        end

        @(negedge clk);
        al.bready = 1;

/*
这种等待提前拉高ready, 等待valid的情况需要注意, 用do while
        // while (!al.bvalid) begin    // 先检查条件, 如果条件不满足, 就直接跳出了, 不会等框里面的上升沿
        //     @(posedge clk);
        // end
如果 bvalid 在拉高 bready 时已经为 1，普通 while 会直接跳过
*/

        do @(posedge clk); while(!al.bvalid);   // 先等一次上升沿, 再检查条件

        @(negedge clk);
        al.bready = 0;   // [Learn] task里面的赋值是持续存在, 信号会保留最后一次赋值的值

    endtask


// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-

    task automatic read_mode(
        input [7:0] mode,
        output int value
    );
        @(negedge clk);
        al.araddr = mode;
        al.arvalid = 1;
        al.rready = 0;

        // DUT更新ready的那个上升沿, 这里的while其实读到的还是ready的旧知, 所以需要再仿真一个上升沿, while才能退出
        do @(posedge clk); while (!(al.arvalid && al.arready));    // 先等待时钟沿，再检查。

// 假设 arready 还没拉高，那么仿真就会一直执行这个 while，时间无法向前推进，时钟也就无法产生下一个上升沿。这会导致仿真卡死。
        // while(!(al.arvalid && al.arready));

    // 这样写也可以
        // while(!(al.arvalid && al.arready)) begin  // 先检查，再决定是否等待时钟沿。
        //     @(posedge clk);
        // end

        @(negedge clk);
        al.arvalid = 0;
        al.rready = 1;

        do @(posedge clk); while (!(al.rvalid && al.rready));
        value = al.rdata;   // 这里没有时钟约束, 所以是在posedge的一瞬间进行采样, 还是能够采到握手那一刻的有效rdata值

        @(negedge clk);
        al.rready = 0;

    endtask

// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-
// 发送一个像素
    task automatic send_pixel(
        input int data
    );
        @(negedge clk);
        as.tkeep = 1;
        as.tdata = data;
        as.tvalid = 1;

        while (!(as.tvalid && as.tready)) begin
            @(posedge clk);
        end

        @(negedge clk);
        as.tvalid = 0;
        as.tkeep = 0;

    endtask


// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-
    /*
    通过axi-stream发送一帧 256*256的图像数据, 图像采用固定图像
    每一行的灰度值都是 0-255
    
    */
    task automatic send_frame;
    for (int i = 0; i < 256; i++) begin
        for (int j = 0; j < 256; j++) begin
            send_pixel(j);
        end
    end

    endtask



endmodule

