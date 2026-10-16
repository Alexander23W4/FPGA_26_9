
/*
基础svtb的构建流程:
-> 设置timescale
-> 设置时钟

-> 初始化顶层信号(如果是协议信号就定义成interface)并连接DUT 
-> 设计task (给DUT设计好的激励, 基于待测的feature, 比如我们这里测DUT接收mode命令和过图能力, 就设置传图和传mode的task)
            (一般来说cpu不需要这一步(cpu更直接, 就是从存储器读), 但是ASIC需要特定的激励task输入)

-> 激励流的设定 initial

-> 在仿真环境基础上搭建infrastructure: trace(必用, $display)  difftest  
            (由于没有cml, 所以没有sdb, gdb可以用)

-> 看波形和trace, difftest 进行debug


想display DUT内部的信号来完善trace, 怎么弄

首先要lint, 检查语法问题
然后运行仿真, 观察trace和波形

*/
`timescale 1ps/1ps

interface axi_lite;
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


interface axi_stream;

    logic [63:0] tdata;
    logic        tvalid;
    logic        tready;
    logic        tlast;
    logic [7:0]  tkeep;
    logic        tuser;
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

    axi_lite al();
    axi_stream as();

    top1 u_top(
        .clk(clk),
        .rst(rst),
        .pclk(pclk),
        .pclk_x5(pclk_x5),

        .s_axis_tdata(as.tdata),
        .s_axis_tvalid(as.tvalid),
        .s_axis_tready(as.tready),
        .s_axis_tlast(as.tlast),
        .s_axis_tkeep(as.tkeep),
        .s_axis_tuser(as.tuser),

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
        .rready(al.rready)
    );

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

        // ★: 注意, 这种写法是一次性等待, 只等一次下降沿就过, 只生效一次
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


    task automatic wait_output_frame;
        do @(posedge clk);
        while (!(u_top.hdl_eof && u_top.hdl_ready));

        @(posedge clk);
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



// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-

task automatic print_pl_status(
    input int threshold_set_mode,
    input int threshold,
    input int video_mode,
    input int area_data
);
    $display("========== PL STATUS ==========");
    $display("threshold_set_mode = %0d", threshold_set_mode);
    $display("threshold          = %0d", threshold);
    $display("video_mode         = %0d", video_mode);
    $display("area_data          = %0d", area_data);
    $display();
endtask


// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-

/*
激励流的设计: 
发10张图, 每发1张图就改一下手动阈值, 并且回读PL所有状态
*/
// 用always 块控制流输出比monitor更可控
    // reg [15:0] fb_read_addr_sample;
    // always @(posedge pclk) begin
    //     fb_read_addr_sample = u_top.fb_read_addr;
    //     #1; // 等待同步 BRAM 的非阻塞读数据更新
    //     // vid_de 包含整个 640x480 可见区；这里只打印 256x256 图像像素。
    //     if (!rst &&
    //         u_top.u_hdmi_out.vcnt >= 10'd112 && u_top.u_hdmi_out.vcnt <= 10'd367 &&
    //         u_top.u_hdmi_out.hcnt >= 10'd192 && u_top.u_hdmi_out.hcnt <= 10'd447)
    //         $display("[%0t] READ  bank=%0d addr=%0d col=%0d pixel=%0d",
    //                 $time,
    //                 u_top.fb_read_idx,
    //                 fb_read_addr_sample,
    //                 fb_read_addr_sample % 256,
    //                 u_top.fb_read_data);
    // end

    always @(posedge clk) begin
        if (!rst && u_top.fb_write_en)
            $display("[%0t] WRITE bank=%0d addr=%0d col=%0d pixel=%0d",
                    $time,
                    u_top.fb_write_idx,
                    u_top.fb_write_addr,
                    u_top.fb_write_addr % 256,
                    u_top.fb_write_data);
    end

initial begin: test_sequence

    int threshold_set_mode;
    int threshold;
    int video_mode;
    int area_data;

//  ####################################################
// 注意这部分, 信号初始化和reset要有
    clk = 0;
    pclk = 0;
    pclk_x5 = 0;
    rst = 1;

    al.awaddr = '0;
    al.awvalid = 0;
    al.wdata = '0;
    al.wstrb = '0;
    al.wvalid = 0;
    al.bready = 0;
    al.araddr = '0;
    al.arvalid = 0;
    al.rready = 0;

    as.tdata = '0;
    as.tvalid = 0;
    as.tlast = 0;
    as.tkeep = '0;
    as.tuser = 0;

    repeat (5) @(posedge clk);

    @(negedge clk);
    rst = 0;

//  ######################################################

    send_frame();
    // wait_output_frame();
    $display("[%0t] before delay", $time);
    #2000000;
    $display("[%0t] after delay", $time);

    for (int i = 0; i < 10; i++) begin
        $display("[RUN] %0d", i);
        set_mode(8'h04, 1);
        set_mode(8'h80, i * 20);
        set_mode(8'h08, i % 3);

        send_frame();
        // wait_output_frame();
        $display("[%0t] before delay, frame %0d", $time, i);
        #2000000;
        $display("[%0t] after delay, frame %0d", $time, i);
        read_mode(8'h04, threshold_set_mode);
        read_mode(8'h80, threshold);
        read_mode(8'h08, video_mode);
        read_mode(8'h84, area_data);

        print_pl_status(threshold_set_mode, threshold, video_mode, area_data);
    end

    $display("[TEST] All tests completed");
    $finish;

end

endmodule

