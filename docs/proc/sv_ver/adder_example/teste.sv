
`include "environment.sv"

program test(intf intf);
  
  //declaring environment instance
  environment env;
  
  initial begin
    env = new(intf);
    
    env.gen.repeat_cnt = 10;

    env.run();
  end
  
endprogram