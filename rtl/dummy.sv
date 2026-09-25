module dummy (
    input  wire         aclk, aresetn,
    input  wire [15:0]  px_data,
    input  wire         px_valid, px_sof, px_eol, px_eof,
    output wire         px_ready,
    output wire [15:0]  res_data,
    output wire         res_valid, res_sof, res_eol, res_eof,
    input  wire         res_ready
);
    

endmodule