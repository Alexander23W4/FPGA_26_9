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
    input      [7:0]    write_data      // 要写入的灰度值
);

    localparam integer DEPTH = 65536;

    // ---- 两个存储区：强制 Block RAM ----
    (* ram_style = "block" *) reg [7:0] mem0 [0:DEPTH-1];
    (* ram_style = "block" *) reg [7:0] mem1 [0:DEPTH-1];


    always @(posedge clk) begin
        if (write_en && !write_buf_idx)
            mem0[write_addr] <= write_data;
    end

    always @(posedge clk) begin
        if (write_en && write_buf_idx)
            mem1[write_addr] <= write_data;
    end

    // ---- 读通道：pclk 域，各自一个读口，1 拍延迟，读出后二选一 ----
    reg [7:0] q0;
    reg [7:0] q1;

    always @(posedge pclk) q0 <= mem0[read_addr];
    always @(posedge pclk) q1 <= mem1[read_addr];

    assign read_data = read_buf_idx ? q1 : q0;

endmodule
