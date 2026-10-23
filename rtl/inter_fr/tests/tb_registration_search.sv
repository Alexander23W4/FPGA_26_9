`timescale 1ns/1ps
module search_case #(parameter W=32,H=32,ROI=8,R=2,PERF=0);
    reg clk=0,rst=1,start=0;
    always #5 clk=~clk;
    reg [7:0] reference_frame[0:W*H-1],current_frame[0:W*H-1];
    wire [15:0] ra,ca;
    reg [7:0] rd,cd;
    wire busy,done;
    wire signed [15:0] dx,dy;
    wire [31:0] sad;
    integer cycles=0,begin_cycle,golden,gx,gy,gdist,cost,a,b,base_x,base_y;
    registration_search #(.FRAME_W(W),.FRAME_H(H),.ROI_W(ROI),.ROI_H(ROI),.SEARCH_R(R)) dut(
        .clk(clk),.rst(rst),.start(start),.ref_addr(ra),.cur_addr(ca),.ref_data(rd),.cur_data(cd),
        .busy(busy),.done(done),.best_dx(dx),.best_dy(dy),.best_sad(sad));
    always @(posedge clk)begin rd<=reference_frame[ra];cd<=current_frame[ca];cycles<=cycles+1;end
    function automatic integer magnitude(input integer x);return x<0 ? -x:x;endfunction
    initial begin
        repeat(4)@(negedge clk);rst=0;
        base_x=(W-ROI)/2;base_y=(H-ROI)/2;
        for(integer tc=0;tc<(PERF ? 1:12);tc=tc+1)begin
            for(integer i=0;i<W*H;i=i+1)begin
                // Constant difference forces the complete search without any
                // pruning, and checks equal-cost zero-displacement selection.
                reference_frame[i]=(PERF||tc==0) ? 0 : $urandom_range(0,255);
                current_frame[i]=(PERF||tc==0) ? 1 : $urandom_range(0,255);
            end
            golden=32'h7fffffff;gx=0;gy=0;gdist=32'h7fffffff;
            for(integer oy=-R;oy<=R;oy=oy+1)for(integer ox=-R;ox<=R;ox=ox+1)begin
                cost=0;
                for(integer y=0;y<ROI;y=y+1)for(integer x=0;x<ROI;x=x+1)begin
                    a=reference_frame[(base_y+y)*W+base_x+x];
                    b=current_frame[(base_y+y+oy)*W+base_x+x+ox];
                    if(a>=b) cost=cost+(a-b);
                    else cost=cost+(b-a);
                end
                if(cost<golden || (cost==golden && magnitude(ox)+magnitude(oy)<gdist))begin
                    golden=cost;gx=ox;gy=oy;gdist=magnitude(ox)+magnitude(oy);
                end
            end
            @(negedge clk);start=1;begin_cycle=cycles;
            @(negedge clk);start=0;
            wait(done);@(negedge clk);
            if(sad!==golden || dx!=gx || dy!=gy)
                $fatal(1,"search case %0d got %0d,%0d SAD %0d expected %0d,%0d SAD %0d",tc,dx,dy,sad,gx,gy,golden);
            if(cycles-begin_cycle>(2*R+1)*(2*R+1)*(ROI*ROI+10)+10)
                $fatal(1,"search exceeded single-pixel pipeline cycle budget");
            if(PERF)$display("DEFAULT_SEARCH clocks=%0d search_ms_at_80MHz=%0f",cycles-begin_cycle,(cycles-begin_cycle)/80000.0);
        end
        $display("[PASS] search exact against brute-force golden, PERF=%0d",PERF);$finish;
    end
    initial begin #100000000;$fatal(1,"search timeout");end
endmodule
module tb_registration_search;search_case dut();endmodule
module tb_registration_perf;search_case #(.W(256),.H(256),.ROI(48),.R(8),.PERF(1)) dut();endmodule
