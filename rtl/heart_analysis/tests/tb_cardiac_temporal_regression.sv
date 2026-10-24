`timescale 1ns/1ps
// Regression of short-lived extra phase pairs observed on normal-23-4.
// Geometry from the real source annotations; this is not an EF ground truth.
module tb_cardiac_temporal_regression;
 reg clk=0,rst=1,frame_valid=0;
 always #5 clk=~clk;
 reg [127:0] values=0;
 wire [127:0] ed,es;
 wire valid,updated;
 wire [31:0] ed_id,es_id;
 integer updates=0;
 reg [31:0] source_lv[0:64]='{3903900,4386684,4094359,4154442,3646682,2994409,3609847,3548114,2624722,2898669,2764287,2463008,1927210,2116805,2027976,2005907,2876835,3085279,3955658,3925184,4072839,3633487,3226730,3525024,4032469,4730610,3942620,3831015,3878531,3837455,2876992,2452798,2292106,2010541,2261004,2129371,2295090,1946688,2470234,2668704,4032312,3632859,3816721,2962757,4171563,4018568,4914236,4422263,3952123,4242956,3176386,3162327,2998414,2761146,2588594,2314882,2208068,2291949,2268308,2826491,2944929,3644483,4335712,5130299,4950050};
 ed_es_tracker dut(.clk(clk),.rst(rst),.frame_valid(frame_valid),.frame_good(1'b1),
  .volumes_x100(values),.ed_values(ed),.es_values(es),.result_valid(valid),.result_updated(updated),
  .ed_frame_id(ed_id),.es_frame_id(es_id),.frame_id());
 always @(posedge clk)if(!rst && updated)begin
  if(updates==0 && !(ed_id>=18 && ed_id<=26 && es_id>=30 && es_id<=38))
   $fatal(1,"early/spurious first phase pair %0d/%0d",ed_id,es_id);
  if(updates==1 && !(ed_id>=40 && ed_id<=48 && es_id>=53 && es_id<=59))
   $fatal(1,"spurious second phase pair %0d/%0d",ed_id,es_id);
  if(updates>=2)$fatal(1,"short local fluctuations became extra cycles");
  if(ed[95:64]!==source_lv[ed_id] || es[95:64]!==source_lv[es_id])
   $fatal(1,"filtered value was substituted for original-frame snapshot");
  updates++;
 end
 initial begin
  repeat(4)@(negedge clk);rst=0;
  for(int i=0;i<65;i++)begin
   @(negedge clk);values={32'd1000,source_lv[i],32'd1000,32'd1000};frame_valid=1;
   @(negedge clk);frame_valid=0;
  end
  repeat(10)@(negedge clk);
  if(updates!=2)$fatal(1,"expected 2 complete contractions; got %0d",updates);
  $display("[PASS] tb_cardiac_temporal_regression: real noisy curve, short false pairs suppressed, original-frame values retained");$finish;
 end
 initial begin #100000;$fatal(1,"temporal regression timeout");end
endmodule
