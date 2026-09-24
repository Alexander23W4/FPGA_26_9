// TMDS encoder. The output is a 10-bit symbol for an external 10:1 serializer.
module tmds_encoder (
    input  logic       clk,
    input  logic       rst_n,
    input  logic [7:0] data_in,
    input  logic       data_enable,
    input  logic [1:0] control,
    output logic [9:0] symbol
);
    logic signed [4:0] disparity;
    logic [8:0] q_m;
    logic [3:0] ones_data;
    integer i;

    always_comb begin
        ones_data = 4'd0;
        for (i = 0; i < 8; i = i + 1)
            ones_data = ones_data + data_in[i];

        q_m[0] = data_in[0];
        if ((ones_data > 4) || ((ones_data == 4) && !data_in[0])) begin
            for (i = 1; i < 8; i = i + 1)
                q_m[i] = q_m[i-1] ^~ data_in[i];
            q_m[8] = 1'b0;
        end else begin
            for (i = 1; i < 8; i = i + 1)
                q_m[i] = q_m[i-1] ^ data_in[i];
            q_m[8] = 1'b1;
        end
    end

    integer ones_qm;
    integer balance;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            disparity <= 5'sd0;
            symbol    <= 10'b1101010100;
        end else if (!data_enable) begin
            disparity <= 5'sd0;
            case (control)
                2'b00: symbol <= 10'b1101010100;
                2'b01: symbol <= 10'b0010101011;
                2'b10: symbol <= 10'b0101010100;
                default: symbol <= 10'b1010101011;
            endcase
        end else begin
            ones_qm = 0;
            for (i = 0; i < 8; i = i + 1)
                ones_qm = ones_qm + q_m[i];
            balance = (ones_qm * 2) - 8;

            if ((disparity == 0) || (ones_qm == 4)) begin
                symbol <= {~q_m[8], q_m[8], (q_m[8] ? q_m[7:0] : ~q_m[7:0])};
                disparity <= disparity + (q_m[8] ? balance : -balance);
            end else if ((disparity[4] == (balance[31] == 1'b0)) && (balance != 0)) begin
                symbol <= {1'b1, q_m[8], ~q_m[7:0]};
                disparity <= disparity + (q_m[8] ? -balance : (2 - balance));
            end else begin
                symbol <= {1'b0, q_m[8], q_m[7:0]};
                disparity <= disparity + (q_m[8] ? (2 + balance) : balance);
            end
        end
    end
endmodule
