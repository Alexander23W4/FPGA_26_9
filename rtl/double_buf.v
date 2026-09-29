/*
读写通道分离
*/

module double_buf (
    input read_buf_idx,
    input write_buf_idx,
    input [15:0] read_addr,
    input [15:0] write_addr,
    input [7:0] read_data,
    output [7:0] write_data
);
    
endmodule

