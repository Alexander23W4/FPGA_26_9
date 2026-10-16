`timescale 1ns / 1ps

/*
读写通道分离

建立两个 256x256x8的 BRAM 存储区
buf_idx 选择 read/write 的存储区


*/

module double_buf (
    input               clk,
    input               pclk,

    input               write_en,       

    input               read_buf_idx,   // 读 bank 选择：0 -> bank0, 1 -> bank1
    input               write_buf_idx,  // 写 bank 选择：0 -> bank0, 1 -> bank1
    input      [15:0]   read_addr,      // 读地址 0..65535
    input      [15:0]   write_addr,     // 写地址 0..65535

    output     [7:0]    read_data,      // 读出的灰度值（1 拍延迟）
    input      [7:0]    write_data,     // 要写入的灰度值
    input              write_mask,
    input              write_contour,
    output             read_mask,
    output             read_contour
);

    localparam integer DEPTH = 65536;

    // ---- 两个存储区：强制 Block RAM ----
    (* ram_style = "block" *) reg [7:0] mem0 [0:DEPTH-1];
    (* ram_style = "block" *) reg mem0_mask [0:DEPTH-1];
    (* ram_style = "block" *) reg mem0_contour [0:DEPTH-1];
    (* ram_style = "block" *) reg [7:0] mem1 [0:DEPTH-1];
    (* ram_style = "block" *) reg mem1_mask [0:DEPTH-1];
    (* ram_style = "block" *) reg mem1_contour [0:DEPTH-1];


    always @(posedge clk) begin
        if (write_en && !write_buf_idx) begin
            mem0[write_addr] <= write_data;
            mem0_mask[write_addr] <= write_mask;
            mem0_contour[write_addr] <= write_contour;
        end
    end

    always @(posedge clk) begin
        if (write_en && write_buf_idx) begin
            mem1[write_addr] <= write_data;
            mem1_mask[write_addr] <= write_mask;
            mem1_contour[write_addr] <= write_contour;
        end
    end

    // ---- 读通道：pclk 域，各自一个读口，1 拍延迟，读出后二选一 ----
    reg [7:0] q0;
    reg [7:0] q1;
    reg q0_mask, q1_mask, q0_contour, q1_contour;

    always @(posedge pclk) q0 <= mem0[read_addr];
    always @(posedge pclk) q1 <= mem1[read_addr];
    always @(posedge pclk) begin
        q0_mask <= mem0_mask[read_addr];
        q1_mask <= mem1_mask[read_addr];
        q0_contour <= mem0_contour[read_addr];
        q1_contour <= mem1_contour[read_addr];
    end

    assign read_data = read_buf_idx ? q1 : q0;
    assign read_mask = read_buf_idx ? q1_mask : q0_mask;
    assign read_contour = read_buf_idx ? q1_contour : q0_contour;

endmodule
