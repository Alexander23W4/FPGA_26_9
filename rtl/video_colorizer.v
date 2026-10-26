`timescale 1ns / 1ps

// Processing modes: 0 gray, 1 white contour, 2 binary mask, 3 red overlay, 4 heatmap.
// Medical mode 1: colored contours only; mode 3: alpha masks only.
// Alpha is overlay opacity: 0 = transparent, 100 = solid red.
// No real arithmetic or per-pixel division. All video signals have equal latency.
module video_colorizer #(parameter integer CHAMBERS=1) (
    input wire pclk, input wire rst,
    input wire [7:0] gray, input wire [CHAMBERS-1:0] mask, contour,
    input tri0 medical,
    input wire [31:0] mode, input wire [6:0] alpha,
    input wire image_active, input wire in_hs, input wire in_vs, input wire in_de,
    output reg [7:0] r, output reg [7:0] g, output reg [7:0] b,
    output reg hs, output reg vs, output reg de
);
    wire [6:0] alpha_safe = alpha > 100 ? 7'd100 : alpha;
    wire [15:0] gray_weighted = {9'd0, (7'd100-alpha_safe)} * {8'd0, gray};
    wire [15:0] red_weighted = gray_weighted + {9'd0, alpha_safe} * 16'd255;
    reg [15:0] s1_gray_weighted, s1_red_weighted;
    reg [7:0] s1_gray;
    reg [23:0] s1_heat;
    reg [31:0] s1_mode;
    reg s1_mask, s1_contour, s1_image, s1_hs, s1_vs, s1_de;
    reg s1_medical;
    reg [23:0] s1_contour_color;
    reg [15:0] s1_med_r, s1_med_g, s1_med_b;
    // LA red, RA yellow, LV green, RV blue. Overlap priority LA > RA > LV > RV.
    function [23:0] chamber_color;
        input [3:0] bits_in;
        begin
            if (bits_in[0]) chamber_color=24'hff0000;
            else if (bits_in[1]) chamber_color=24'hffff00;
            else if (bits_in[2]) chamber_color=24'h00ff00;
            else if (bits_in[3]) chamber_color=24'h0000ff;
            else chamber_color=0;
        end
    endfunction
    wire [23:0] mask_color=chamber_color(mask);
    wire [23:0] ctr_color=chamber_color(contour);
    wire [15:0] med_r=mask_color[23] ? red_weighted : gray_weighted;
    wire [15:0] med_g=mask_color[15] ? red_weighted : gray_weighted;
    wire [15:0] med_b=mask_color[7] ? red_weighted : gray_weighted;

    // Exact floor(x/100) for every x in 0..25500.
    function [7:0] divide_100;
        input [15:0] value;
        reg [31:0] product;
        begin
            product = value * 16'd5243;
            divide_100 = product[26:19];
        end
    endfunction

    // Integer LUT, with knots:
    // 0:(0,0,128), 51:(0,0,255), 102:(0,255,255),
    // 153:(0,255,0), 204:(255,255,0), 255:(128,0,0).
    function [23:0] heatmap_color;
        input [7:0] value;
        begin
            case (value)
                8'd0: heatmap_color = 24'h000080;
                8'd1: heatmap_color = 24'h000082;
                8'd2: heatmap_color = 24'h000084;
                8'd3: heatmap_color = 24'h000087;
                8'd4: heatmap_color = 24'h000089;
                8'd5: heatmap_color = 24'h00008c;
                8'd6: heatmap_color = 24'h00008e;
                8'd7: heatmap_color = 24'h000091;
                8'd8: heatmap_color = 24'h000093;
                8'd9: heatmap_color = 24'h000096;
                8'd10: heatmap_color = 24'h000098;
                8'd11: heatmap_color = 24'h00009b;
                8'd12: heatmap_color = 24'h00009d;
                8'd13: heatmap_color = 24'h0000a0;
                8'd14: heatmap_color = 24'h0000a2;
                8'd15: heatmap_color = 24'h0000a5;
                8'd16: heatmap_color = 24'h0000a7;
                8'd17: heatmap_color = 24'h0000aa;
                8'd18: heatmap_color = 24'h0000ac;
                8'd19: heatmap_color = 24'h0000af;
                8'd20: heatmap_color = 24'h0000b1;
                8'd21: heatmap_color = 24'h0000b4;
                8'd22: heatmap_color = 24'h0000b6;
                8'd23: heatmap_color = 24'h0000b9;
                8'd24: heatmap_color = 24'h0000bb;
                8'd25: heatmap_color = 24'h0000be;
                8'd26: heatmap_color = 24'h0000c0;
                8'd27: heatmap_color = 24'h0000c3;
                8'd28: heatmap_color = 24'h0000c5;
                8'd29: heatmap_color = 24'h0000c8;
                8'd30: heatmap_color = 24'h0000ca;
                8'd31: heatmap_color = 24'h0000cd;
                8'd32: heatmap_color = 24'h0000cf;
                8'd33: heatmap_color = 24'h0000d2;
                8'd34: heatmap_color = 24'h0000d4;
                8'd35: heatmap_color = 24'h0000d7;
                8'd36: heatmap_color = 24'h0000d9;
                8'd37: heatmap_color = 24'h0000dc;
                8'd38: heatmap_color = 24'h0000de;
                8'd39: heatmap_color = 24'h0000e1;
                8'd40: heatmap_color = 24'h0000e3;
                8'd41: heatmap_color = 24'h0000e6;
                8'd42: heatmap_color = 24'h0000e8;
                8'd43: heatmap_color = 24'h0000eb;
                8'd44: heatmap_color = 24'h0000ed;
                8'd45: heatmap_color = 24'h0000f0;
                8'd46: heatmap_color = 24'h0000f2;
                8'd47: heatmap_color = 24'h0000f5;
                8'd48: heatmap_color = 24'h0000f7;
                8'd49: heatmap_color = 24'h0000fa;
                8'd50: heatmap_color = 24'h0000fc;
                8'd51: heatmap_color = 24'h0000ff;
                8'd52: heatmap_color = 24'h0005ff;
                8'd53: heatmap_color = 24'h000aff;
                8'd54: heatmap_color = 24'h000fff;
                8'd55: heatmap_color = 24'h0014ff;
                8'd56: heatmap_color = 24'h0019ff;
                8'd57: heatmap_color = 24'h001eff;
                8'd58: heatmap_color = 24'h0023ff;
                8'd59: heatmap_color = 24'h0028ff;
                8'd60: heatmap_color = 24'h002dff;
                8'd61: heatmap_color = 24'h0032ff;
                8'd62: heatmap_color = 24'h0037ff;
                8'd63: heatmap_color = 24'h003cff;
                8'd64: heatmap_color = 24'h0041ff;
                8'd65: heatmap_color = 24'h0046ff;
                8'd66: heatmap_color = 24'h004bff;
                8'd67: heatmap_color = 24'h0050ff;
                8'd68: heatmap_color = 24'h0055ff;
                8'd69: heatmap_color = 24'h005aff;
                8'd70: heatmap_color = 24'h005fff;
                8'd71: heatmap_color = 24'h0064ff;
                8'd72: heatmap_color = 24'h0069ff;
                8'd73: heatmap_color = 24'h006eff;
                8'd74: heatmap_color = 24'h0073ff;
                8'd75: heatmap_color = 24'h0078ff;
                8'd76: heatmap_color = 24'h007dff;
                8'd77: heatmap_color = 24'h0082ff;
                8'd78: heatmap_color = 24'h0087ff;
                8'd79: heatmap_color = 24'h008cff;
                8'd80: heatmap_color = 24'h0091ff;
                8'd81: heatmap_color = 24'h0096ff;
                8'd82: heatmap_color = 24'h009bff;
                8'd83: heatmap_color = 24'h00a0ff;
                8'd84: heatmap_color = 24'h00a5ff;
                8'd85: heatmap_color = 24'h00aaff;
                8'd86: heatmap_color = 24'h00afff;
                8'd87: heatmap_color = 24'h00b4ff;
                8'd88: heatmap_color = 24'h00b9ff;
                8'd89: heatmap_color = 24'h00beff;
                8'd90: heatmap_color = 24'h00c3ff;
                8'd91: heatmap_color = 24'h00c8ff;
                8'd92: heatmap_color = 24'h00cdff;
                8'd93: heatmap_color = 24'h00d2ff;
                8'd94: heatmap_color = 24'h00d7ff;
                8'd95: heatmap_color = 24'h00dcff;
                8'd96: heatmap_color = 24'h00e1ff;
                8'd97: heatmap_color = 24'h00e6ff;
                8'd98: heatmap_color = 24'h00ebff;
                8'd99: heatmap_color = 24'h00f0ff;
                8'd100: heatmap_color = 24'h00f5ff;
                8'd101: heatmap_color = 24'h00faff;
                8'd102: heatmap_color = 24'h00ffff;
                8'd103: heatmap_color = 24'h00fffa;
                8'd104: heatmap_color = 24'h00fff5;
                8'd105: heatmap_color = 24'h00fff0;
                8'd106: heatmap_color = 24'h00ffeb;
                8'd107: heatmap_color = 24'h00ffe6;
                8'd108: heatmap_color = 24'h00ffe1;
                8'd109: heatmap_color = 24'h00ffdc;
                8'd110: heatmap_color = 24'h00ffd7;
                8'd111: heatmap_color = 24'h00ffd2;
                8'd112: heatmap_color = 24'h00ffcd;
                8'd113: heatmap_color = 24'h00ffc8;
                8'd114: heatmap_color = 24'h00ffc3;
                8'd115: heatmap_color = 24'h00ffbe;
                8'd116: heatmap_color = 24'h00ffb9;
                8'd117: heatmap_color = 24'h00ffb4;
                8'd118: heatmap_color = 24'h00ffaf;
                8'd119: heatmap_color = 24'h00ffaa;
                8'd120: heatmap_color = 24'h00ffa5;
                8'd121: heatmap_color = 24'h00ffa0;
                8'd122: heatmap_color = 24'h00ff9b;
                8'd123: heatmap_color = 24'h00ff96;
                8'd124: heatmap_color = 24'h00ff91;
                8'd125: heatmap_color = 24'h00ff8c;
                8'd126: heatmap_color = 24'h00ff87;
                8'd127: heatmap_color = 24'h00ff82;
                8'd128: heatmap_color = 24'h00ff7d;
                8'd129: heatmap_color = 24'h00ff78;
                8'd130: heatmap_color = 24'h00ff73;
                8'd131: heatmap_color = 24'h00ff6e;
                8'd132: heatmap_color = 24'h00ff69;
                8'd133: heatmap_color = 24'h00ff64;
                8'd134: heatmap_color = 24'h00ff5f;
                8'd135: heatmap_color = 24'h00ff5a;
                8'd136: heatmap_color = 24'h00ff55;
                8'd137: heatmap_color = 24'h00ff50;
                8'd138: heatmap_color = 24'h00ff4b;
                8'd139: heatmap_color = 24'h00ff46;
                8'd140: heatmap_color = 24'h00ff41;
                8'd141: heatmap_color = 24'h00ff3c;
                8'd142: heatmap_color = 24'h00ff37;
                8'd143: heatmap_color = 24'h00ff32;
                8'd144: heatmap_color = 24'h00ff2d;
                8'd145: heatmap_color = 24'h00ff28;
                8'd146: heatmap_color = 24'h00ff23;
                8'd147: heatmap_color = 24'h00ff1e;
                8'd148: heatmap_color = 24'h00ff19;
                8'd149: heatmap_color = 24'h00ff14;
                8'd150: heatmap_color = 24'h00ff0f;
                8'd151: heatmap_color = 24'h00ff0a;
                8'd152: heatmap_color = 24'h00ff05;
                8'd153: heatmap_color = 24'h00ff00;
                8'd154: heatmap_color = 24'h05ff00;
                8'd155: heatmap_color = 24'h0aff00;
                8'd156: heatmap_color = 24'h0fff00;
                8'd157: heatmap_color = 24'h14ff00;
                8'd158: heatmap_color = 24'h19ff00;
                8'd159: heatmap_color = 24'h1eff00;
                8'd160: heatmap_color = 24'h23ff00;
                8'd161: heatmap_color = 24'h28ff00;
                8'd162: heatmap_color = 24'h2dff00;
                8'd163: heatmap_color = 24'h32ff00;
                8'd164: heatmap_color = 24'h37ff00;
                8'd165: heatmap_color = 24'h3cff00;
                8'd166: heatmap_color = 24'h41ff00;
                8'd167: heatmap_color = 24'h46ff00;
                8'd168: heatmap_color = 24'h4bff00;
                8'd169: heatmap_color = 24'h50ff00;
                8'd170: heatmap_color = 24'h55ff00;
                8'd171: heatmap_color = 24'h5aff00;
                8'd172: heatmap_color = 24'h5fff00;
                8'd173: heatmap_color = 24'h64ff00;
                8'd174: heatmap_color = 24'h69ff00;
                8'd175: heatmap_color = 24'h6eff00;
                8'd176: heatmap_color = 24'h73ff00;
                8'd177: heatmap_color = 24'h78ff00;
                8'd178: heatmap_color = 24'h7dff00;
                8'd179: heatmap_color = 24'h82ff00;
                8'd180: heatmap_color = 24'h87ff00;
                8'd181: heatmap_color = 24'h8cff00;
                8'd182: heatmap_color = 24'h91ff00;
                8'd183: heatmap_color = 24'h96ff00;
                8'd184: heatmap_color = 24'h9bff00;
                8'd185: heatmap_color = 24'ha0ff00;
                8'd186: heatmap_color = 24'ha5ff00;
                8'd187: heatmap_color = 24'haaff00;
                8'd188: heatmap_color = 24'hafff00;
                8'd189: heatmap_color = 24'hb4ff00;
                8'd190: heatmap_color = 24'hb9ff00;
                8'd191: heatmap_color = 24'hbeff00;
                8'd192: heatmap_color = 24'hc3ff00;
                8'd193: heatmap_color = 24'hc8ff00;
                8'd194: heatmap_color = 24'hcdff00;
                8'd195: heatmap_color = 24'hd2ff00;
                8'd196: heatmap_color = 24'hd7ff00;
                8'd197: heatmap_color = 24'hdcff00;
                8'd198: heatmap_color = 24'he1ff00;
                8'd199: heatmap_color = 24'he6ff00;
                8'd200: heatmap_color = 24'hebff00;
                8'd201: heatmap_color = 24'hf0ff00;
                8'd202: heatmap_color = 24'hf5ff00;
                8'd203: heatmap_color = 24'hfaff00;
                8'd204: heatmap_color = 24'hffff00;
                8'd205: heatmap_color = 24'hfdfa00;
                8'd206: heatmap_color = 24'hfbf500;
                8'd207: heatmap_color = 24'hf8f000;
                8'd208: heatmap_color = 24'hf6eb00;
                8'd209: heatmap_color = 24'hf3e600;
                8'd210: heatmap_color = 24'hf1e100;
                8'd211: heatmap_color = 24'heedc00;
                8'd212: heatmap_color = 24'hecd700;
                8'd213: heatmap_color = 24'he9d200;
                8'd214: heatmap_color = 24'he7cd00;
                8'd215: heatmap_color = 24'he4c800;
                8'd216: heatmap_color = 24'he2c300;
                8'd217: heatmap_color = 24'hdfbe00;
                8'd218: heatmap_color = 24'hddb900;
                8'd219: heatmap_color = 24'hdab400;
                8'd220: heatmap_color = 24'hd8af00;
                8'd221: heatmap_color = 24'hd5aa00;
                8'd222: heatmap_color = 24'hd3a500;
                8'd223: heatmap_color = 24'hd0a000;
                8'd224: heatmap_color = 24'hce9b00;
                8'd225: heatmap_color = 24'hcb9600;
                8'd226: heatmap_color = 24'hc99100;
                8'd227: heatmap_color = 24'hc68c00;
                8'd228: heatmap_color = 24'hc48700;
                8'd229: heatmap_color = 24'hc18200;
                8'd230: heatmap_color = 24'hbf7d00;
                8'd231: heatmap_color = 24'hbc7800;
                8'd232: heatmap_color = 24'hba7300;
                8'd233: heatmap_color = 24'hb76e00;
                8'd234: heatmap_color = 24'hb56900;
                8'd235: heatmap_color = 24'hb26400;
                8'd236: heatmap_color = 24'hb05f00;
                8'd237: heatmap_color = 24'had5a00;
                8'd238: heatmap_color = 24'hab5500;
                8'd239: heatmap_color = 24'ha85000;
                8'd240: heatmap_color = 24'ha64b00;
                8'd241: heatmap_color = 24'ha34600;
                8'd242: heatmap_color = 24'ha14100;
                8'd243: heatmap_color = 24'h9e3c00;
                8'd244: heatmap_color = 24'h9c3700;
                8'd245: heatmap_color = 24'h993200;
                8'd246: heatmap_color = 24'h972d00;
                8'd247: heatmap_color = 24'h942800;
                8'd248: heatmap_color = 24'h922300;
                8'd249: heatmap_color = 24'h8f1e00;
                8'd250: heatmap_color = 24'h8d1900;
                8'd251: heatmap_color = 24'h8a1400;
                8'd252: heatmap_color = 24'h880f00;
                8'd253: heatmap_color = 24'h850a00;
                8'd254: heatmap_color = 24'h830500;
                8'd255: heatmap_color = 24'h800000;
                default: heatmap_color = 24'h000080;
            endcase
        end
    endfunction

    always @(posedge pclk) begin
        if (rst) begin
            s1_gray_weighted <= 0; s1_red_weighted <= 0;
            s1_medical <= 0; s1_contour_color <= 0;
            s1_med_r <= 0; s1_med_g <= 0; s1_med_b <= 0;
            s1_gray <= 0; s1_heat <= 0; s1_mode <= 0;
            s1_mask <= 0; s1_contour <= 0; s1_image <= 0;
            s1_hs <= 1; s1_vs <= 1; s1_de <= 0;
            r <= 0; g <= 0; b <= 0; hs <= 1; vs <= 1; de <= 0;
        end else begin
            s1_gray_weighted <= gray_weighted; s1_red_weighted <= red_weighted;
            s1_gray <= gray; s1_heat <= heatmap_color(gray); s1_mode <= mode;
            s1_mask <= |mask; s1_contour <= |contour; s1_image <= image_active;
            s1_medical <= medical; s1_contour_color <= ctr_color;
            s1_med_r <= med_r; s1_med_g <= med_g; s1_med_b <= med_b;
            s1_hs <= in_hs; s1_vs <= in_vs; s1_de <= in_de;
            hs <= s1_hs; vs <= s1_vs; de <= s1_de;
            r <= 0; g <= 0; b <= 0;
            if (s1_image && s1_de) begin
                // The same choice applies to HDMI and independent TCP return.
                if (s1_medical) begin
                    if (s1_mode == 1 && s1_contour) begin
                        r<=s1_contour_color[23:16]; g<=s1_contour_color[15:8]; b<=s1_contour_color[7:0];
                    end else if (s1_mode == 3 && s1_mask) begin
                        r<=divide_100(s1_med_r); g<=divide_100(s1_med_g); b<=divide_100(s1_med_b);
                    end else begin r<=s1_gray; g<=s1_gray; b<=s1_gray; end
                end else case (s1_mode)
                    32'd1: begin
                        r <= s1_contour ? 8'hff : s1_gray;
                        g <= s1_contour ? 8'hff : s1_gray;
                        b <= s1_contour ? 8'hff : s1_gray;
                    end
                    32'd2: begin
                        r <= s1_mask ? 8'hff : 8'h00;
                        g <= s1_mask ? 8'hff : 8'h00;
                        b <= s1_mask ? 8'hff : 8'h00;
                    end
                    32'd3: begin
                        r <= s1_mask ? divide_100(s1_red_weighted) : s1_gray;
                        g <= s1_mask ? divide_100(s1_gray_weighted) : s1_gray;
                        b <= s1_mask ? divide_100(s1_gray_weighted) : s1_gray;
                    end
                    32'd4: begin
                        r <= s1_heat[23:16]; g <= s1_heat[15:8]; b <= s1_heat[7:0];
                    end
                    default: begin r <= s1_gray; g <= s1_gray; b <= s1_gray; end
                endcase
            end
        end
    end
endmodule
