/*
      px_data  [15:0]   像素值（一行一行，从左到右，从上到下）
      px_valid          这一拍 px_data 有效
      px_ready          你收不下时拉低（如果 USE_PX_READY=0 则不用管）
      px_sof            一帧的第一个像素
      px_eol            一行的最后一个像素
      px_eof            一帧的最后一个像素
*/

module img2buf #(
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 16,          // 地址位宽
    parameter DEPTH      = 65536        // 深度，必须 = 2^ADDR_WIDTH
)(
    input clk,
    input rst,

    input [PIXEL_W-1:0]          px_data,
    input                        px_valid,
    output                       px_ready,
    input                        px_sof,
    input                        px_eol,
    input                        px_eof,

    output buf_en,
    output buf_we,
    output [ADDR_WIDTH-1:0] buf_addr,
    output [DATA_WIDTH-1:0] buf_din,

    output end_frame
);
    assign end_frame = px_eof;
    
    reg [ADDR_WIDTH-1:0] frame_idx;

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            frame_idx <= '0;
        end else begin
            if(px_valid && px_sof) begin
                frame_idx <= 1;
            end
            if(px_valid && !px_sof) begin
                frame_idx <= frame_idx + 1;
            end
            if(px_eof) begin
                frame_idx <= '0;
            end
         end
    end

    always @(*) begin
        buf_addr = frame_idx;
        if(px_valid) begin
            if(px_sof) begin
                buf_addr = '0;
            end
            buf_en = 1'b1;
            buf_we = 1'b1;
            buf_din = px_data;
        end
    end

endmodule