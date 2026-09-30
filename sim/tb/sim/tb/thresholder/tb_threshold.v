//============================================================
// tb_threshold.v  Testbench for AXI-Stream with contour output
// - Send 256 pixels via AXI-Stream (fast test)
// - Wait for Otsu
// - Host writes threshold via AXI-Lite
// - Check mask and contour output
//============================================================
`timescale 1ns / 1ps

module tb_threshold;

    // ---- Clock and reset ----
    reg        clk        = 0;      // 50 MHz clock
    reg        rst_n      = 0;      // reset, active low

    // ---- AXI-Lite write signals ----
    reg  [31:0] s_axi_awaddr  = 0;  // write address
    reg         s_axi_awvalid = 0;  // write address valid
    wire        s_axi_awready;      // write address ready
    reg  [31:0] s_axi_wdata   = 0;  // write data
    reg  [3:0]  s_axi_wstrb   = 0;  // write byte strobes
    reg         s_axi_wvalid  = 0;  // write data valid
    wire        s_axi_wready;       // write data ready
    wire [1:0]  s_axi_bresp;        // write response
    wire        s_axi_bvalid;       // write response valid
    reg         s_axi_bready  = 1;  // write response ready

    // ---- AXI-Lite read signals ----
    reg  [31:0] s_axi_araddr  = 0;  // read address
    reg         s_axi_arvalid = 0;  // read address valid
    wire        s_axi_arready;      // read address ready
    wire [31:0] s_axi_rdata;        // read data
    wire [1:0]  s_axi_rresp;        // read response
    wire        s_axi_rvalid;       // read data valid
    reg         s_axi_rready  = 1;  // read data ready

    // ---- AXI-Stream slave signals (input to DUT) ----
    reg  [7:0]  s_axis_tdata  = 0;  // input pixel
    reg         s_axis_tvalid = 0;  // input pixel valid
    wire        s_axis_tready;      // input ready (from DUT)
    reg         s_axis_tlast  = 0;  // input frame end

    // ---- AXI-Stream master signals (output from DUT) ----
    wire [7:0]  m_axis_tdata;       // output pixel
    wire        m_axis_tvalid;      // output pixel valid
    reg         m_axis_tready = 1;  // output ready (always 1 in TB)
    wire        m_axis_tlast;       // output frame end
    wire        m_axis_tmask;       // output binary mask
    wire        m_axis_tcontour;    // output contour (NEW)

    // ---- Status outputs from DUT ----
    wire [7:0]  threshold_out;      // current threshold
    wire        auto_mode_out;      // auto/manual mode
    wire        frame_done_out;     // frame done

    // ---- Instantiate DUT ----
    top_threshold_demo u_dut (
        .clk(clk),                          // system clock
        .rst_n(rst_n),                      // reset
        // AXI-Lite
        .s_axi_awaddr(s_axi_awaddr),        // write address
        .s_axi_awvalid(s_axi_awvalid),      // write address valid
        .s_axi_awready(s_axi_awready),      // write address ready
        .s_axi_wdata(s_axi_wdata),          // write data
        .s_axi_wstrb(s_axi_wstrb),          // write strobes
        .s_axi_wvalid(s_axi_wvalid),        // write data valid
        .s_axi_wready(s_axi_wready),        // write data ready
        .s_axi_bresp(s_axi_bresp),          // write response
        .s_axi_bvalid(s_axi_bvalid),        // write response valid
        .s_axi_bready(s_axi_bready),        // write response ready
        .s_axi_araddr(s_axi_araddr),        // read address
        .s_axi_arvalid(s_axi_arvalid),      // read address valid
        .s_axi_arready(s_axi_arready),      // read address ready
        .s_axi_rdata(s_axi_rdata),          // read data
        .s_axi_rresp(s_axi_rresp),          // read response
        .s_axi_rvalid(s_axi_rvalid),        // read data valid
        .s_axi_rready(s_axi_rready),        // read data ready
        // AXI-Stream slave
        .s_axis_tdata(s_axis_tdata),        // input pixel
        .s_axis_tvalid(s_axis_tvalid),      // input valid
        .s_axis_tready(s_axis_tready),      // input ready
        .s_axis_tlast(s_axis_tlast),        // input frame end
        // AXI-Stream master
        .m_axis_tdata(m_axis_tdata),        // output pixel
        .m_axis_tvalid(m_axis_tvalid),      // output valid
        .m_axis_tready(m_axis_tready),      // output ready
        .m_axis_tlast(m_axis_tlast),        // output frame end
        .m_axis_tmask(m_axis_tmask),        // output mask
        .m_axis_tcontour(m_axis_tcontour),  // output contour
        // Status
        .threshold_out(threshold_out),      // current threshold
        .auto_mode_out(auto_mode_out),      // auto/manual mode
        .frame_done_out(frame_done_out)     // frame done
    );

    // ---- 50 MHz clock: period = 20 ns ----
    always #10 clk = ~clk;

    // ---- AXI-Lite write task ----
    task axi_write(input [31:0] addr, input [31:0] data);
        begin
            @(posedge clk);             // wait for clock edge
            s_axi_awaddr  <= addr;      // set write address
            s_axi_awvalid <= 1'b1;      // assert awvalid
            s_axi_wdata   <= data;      // set write data
            s_axi_wstrb   <= 4'hF;      // all bytes
            s_axi_wvalid  <= 1'b1;      // assert wvalid
            repeat(2) @(posedge clk);   // wait handshake
            s_axi_awvalid <= 1'b0;      // deassert awvalid
            s_axi_wvalid  <= 1'b0;      // deassert wvalid
            repeat(3) @(posedge clk);   // wait response
        end
    endtask

    integer i;                          // loop index

    initial begin
        // ---- Step 0: reset ----
        #100;
        rst_n = 1;                      // release reset
        #100;

        // ---- Step 1: send 256 pixels via AXI-Stream ----
        // First 128 = 60, next 128 = 180
        for (i = 0; i < 256; i = i + 1) begin
            @(posedge clk);                                    // wait clock
            s_axis_tvalid <= 1'b1;                             // pixel valid
            s_axis_tdata  <= (i < 128) ? 8'd60 : 8'd180;       // two-peak data
            s_axis_tlast  <= (i == 255);                       // last pixel
        end
        @(posedge clk);
        s_axis_tvalid <= 1'b0;          // stop streaming
        s_axis_tlast  <= 1'b0;          // clear tlast
        repeat(10) @(posedge clk);      // wait a bit

        // ---- Step 2: wait for Otsu ----
        repeat(1000) @(posedge clk);    // wait Otsu (~512 cycles)

        // ---- Step 3: print T1 ----
        $display("=====================================");
        $display("[T1] After Otsu:");
        $display("     auto_mode = %b  (expect 1)", auto_mode_out);
        $display("     threshold = %d  (expect 179)", threshold_out);
        $display("=====================================");

        // ---- Step 4: host writes threshold = 100 ----
        axi_write(32'h08, 32'd100);     // write DATA_REG = 100
        repeat(10) @(posedge clk);
        $display("[T2] auto_mode=%b threshold=%d (expect 0,100)",
                 auto_mode_out, threshold_out);

        // ---- Step 5: host writes threshold = 150 ----
        axi_write(32'h08, 32'd150);     // write DATA_REG = 150
        repeat(10) @(posedge clk);
        $display("[T3] auto_mode=%b threshold=%d (expect 0,150)",
                 auto_mode_out, threshold_out);

        // ---- Step 6: send small pattern to test mask + contour ----
        // Send 8 pixels with pattern: 0 1 1 1 1 1 1 0 (a "blob")
        // This should generate contour edges at both ends
        @(posedge clk);
        s_axis_tvalid <= 1'b1;
        s_axis_tdata  <= 8'd200;        // > 150, mask=1 (edge)
        @(posedge clk);
        s_axis_tdata  <= 8'd200;        // > 150, mask=1 (interior)
        @(posedge clk);
        s_axis_tdata  <= 8'd200;        // > 150, mask=1 (interior)
        @(posedge clk);
        s_axis_tdata  <= 8'd60;         // < 150, mask=0
        repeat(5) @(posedge clk);
        s_axis_tvalid <= 1'b0;
        repeat(20) @(posedge clk);

        // ---- Step 7: done ----
        $display("=====================================");
        $display("Simulation finished");
        $display("=====================================");
        $finish;
    end

endmodule