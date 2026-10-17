`timescale 1ns / 1ps

/*
读写通道分离

建立两个 256x256 的 BRAM 存储区，每个保存灰度、mask、contour
HDMI 与回传各有独立读地址和 bank 选择；clk 口由写端/回传分时使用


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
    output             read_contour,

    // Independent sequential return reader, synchronous to clk.
    input               back_read_en,
    input               back_read_idx,
    input      [15:0]    back_read_addr,
    output     [7:0]     back_read_data,
    output              back_read_mask,
    output              back_read_contour
);

    localparam integer DEPTH = 65536;

    // ---- 两个存储区：强制 Block RAM ----
    (* ram_style = "block" *) reg [7:0] mem0 [0:DEPTH-1];
    (* ram_style = "block" *) reg mem0_mask [0:DEPTH-1];
    (* ram_style = "block" *) reg mem0_contour [0:DEPTH-1];
    (* ram_style = "block" *) reg [7:0] mem1 [0:DEPTH-1];
    (* ram_style = "block" *) reg mem1_mask [0:DEPTH-1];
    (* ram_style = "block" *) reg mem1_contour [0:DEPTH-1];


    // Each bank uses true dual-port RAM: HDMI owns the pclk port; the clk
    // port is shared by the writer and return reader, which own DIFFERENT
    // banks. Sharing this port avoids replicating the whole frame store.
    wire wr0 = write_en && !write_buf_idx;
    wire wr1 = write_en && write_buf_idx;
    wire rd0 = back_read_en && !back_read_idx;
    wire rd1 = back_read_en && back_read_idx;
    wire [15:0] addr0 = wr0 ? write_addr : back_read_addr;
    wire [15:0] addr1 = wr1 ? write_addr : back_read_addr;
    reg [7:0] back_q0, back_q1;
    reg back_mask0, back_mask1, back_contour0, back_contour1;

    always @(posedge clk) begin
        if (write_en && !write_buf_idx) begin
            mem0[addr0] <= write_data;
            mem0_mask[addr0] <= write_mask;
            mem0_contour[addr0] <= write_contour;
        end
        if (rd0) begin
            back_q0 <= mem0[addr0];
            back_mask0 <= mem0_mask[addr0];
            back_contour0 <= mem0_contour[addr0];
        end
    end

    always @(posedge clk) begin
        if (write_en && write_buf_idx) begin
            mem1[addr1] <= write_data;
            mem1_mask[addr1] <= write_mask;
            mem1_contour[addr1] <= write_contour;
        end
        if (rd1) begin
            back_q1 <= mem1[addr1];
            back_mask1 <= mem1_mask[addr1];
            back_contour1 <= mem1_contour[addr1];
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
    assign back_read_data = back_read_idx ? back_q1 : back_q0;
    assign back_read_mask = back_read_idx ? back_mask1 : back_mask0;
    assign back_read_contour = back_read_idx ? back_contour1 : back_contour0;

    // synthesis translate_off
    always @(posedge clk)
        if (write_en && back_read_en && write_buf_idx == back_read_idx)
            $fatal(1, "double_buf: writer and return reader own the same bank");
    // synthesis translate_on

endmodule
