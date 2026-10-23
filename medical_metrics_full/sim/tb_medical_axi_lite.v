`timescale 1ns / 1ps
// Basic AXI4-Lite register test for the 0x40..0x4F medical map.
module tb_medical_axi_lite;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg [8:0] awaddr = 9'd0;
    reg awvalid = 1'b0;
    wire awready;
    reg [31:0] wdata = 32'd0;
    reg [3:0] wstrb = 4'hF;
    reg wvalid = 1'b0;
    wire wready;
    wire [1:0] bresp;
    wire bvalid;
    reg bready = 1'b1;
    reg [8:0] araddr = 9'd0;
    reg arvalid = 1'b0;
    wire arready;
    wire [31:0] rdata;
    wire [1:0] rresp;
    wire rvalid;
    reg rready = 1'b1;
    wire [31:0] ctrl;

    reg signed [15:0] dx = -16'sd7;
    reg signed [15:0] dy = 16'sd3;
    reg [31:0] sad = 32'd1234;
    reg [23:0] area = 24'd200;
    reg [15:0] length = 16'd10;
    reg [63:0] edv = 64'h0000_0000_0123_4567;
    reg [63:0] esv = 64'h0000_0000_0001_2345;
    reg signed [63:0] strain = -64'sd1310720;
    reg [31:0] edf = 32'd2;
    reg [31:0] esf = 32'd9;
    reg [31:0] fid = 32'd12;

    integer errors = 0;
    reg [31:0] rd;
    always #5 clk = ~clk;

    medical_axi_lite dut (
        .clk(clk), .rst(rst),
        .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .araddr(araddr), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
        .ctrl_out(ctrl), .med_status(32'h0000_0005),
        .reg_dx(dx), .reg_dy(dy), .reg_sad(sad),
        .area_px(area), .length_px(length),
        .edv_q16(edv), .esv_q16(esv), .strain_q16(strain),
        .ed_frame(edf), .es_frame(esf), .frame_id(fid)
    );

    task axi_write(input [8:0] addr, input [31:0] data);
        begin
            awaddr = addr; wdata = data; awvalid = 1'b1; wvalid = 1'b1;
            while (!(awready && wready)) @(posedge clk);
            @(posedge clk);
            awvalid = 1'b0; wvalid = 1'b0;
            @(posedge clk);
        end
    endtask

    task axi_read(input [8:0] addr, output [31:0] data);
        begin
            araddr = addr; arvalid = 1'b1;
            while (!arready) @(posedge clk);
            @(posedge clk);
            arvalid = 1'b0;
            while (!rvalid) @(posedge clk);
            data = rdata;
            @(posedge clk);
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        axi_write(9'h100, 32'h0000_0001);
        if (ctrl !== 32'h1) begin
            $display("FAIL: ctrl=%08X expected 00000001", ctrl);
            errors = errors + 1;
        end

        axi_read(9'h104, rd);
        if (rd !== 32'h5) begin $display("FAIL: status=%08X", rd); errors = errors + 1; end
        axi_read(9'h108, rd);
        if (rd !== 32'hFFFF_FFF9) begin $display("FAIL: dx=%08X", rd); errors = errors + 1; end
        axi_read(9'h10C, rd);
        if (rd !== 32'h0000_0003) begin $display("FAIL: dy=%08X", rd); errors = errors + 1; end
        axi_read(9'h114, rd);
        if (rd !== 32'd200) begin $display("FAIL: area=%08X", rd); errors = errors + 1; end

        if (errors == 0) $display("PASS: medical AXI-Lite map");
        else              $display("FAIL: AXI errors=%0d", errors);
        $finish;
    end
endmodule

