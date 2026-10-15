
// driver 从mailbox中获取激励值并用transaction接收, 按照接口时序驱动连接DUT的接口信号
class driver;
    int num_transac;   // driver计数
    mailbox mbx;
    virtual intf itf;
    packet pkt;

    function new(mailbox mbx, intf itf);
        this.mbx = mbx;
        this.itf = itf;
    endfunction

    task automatic send;
        forever begin
            mbx.get(pkt);
            itf.valid = 0;
            itf.a = pkt.a;
            itf.b = pkt.b;

            @(negedge clk);
            itf.valid = 1;

            @(negedge clk);
            itf.valid = 0;

            @(posedge clk);
            pkt.c = itf.c;   // 通常给完输入激励就行, 没必要接收输出

            num_transac++;
            pkt.display("[DRIVER]");   // 在driver可以直接输出 a, b 和 计算之后的 c结果
            // 在这里输出也没太大必要, 可以传给monitor再统一输出, 通常driver给完输入激励就行了
        end
    endtask

endcalss



// 讲义的写法:
class driver; 
  //used to count the number of transactions
  int no_transactions;
  
  //creating virtual interface handle
  virtual intf vif;
  
  //creating mailbox handle
  mailbox gen2driv;
  
  //constructor
  function new(virtual intf vif,mailbox gen2driv);
    //getting the interface
    this.vif = vif;
    //getting the mailbox handles from  environment 
    this.gen2driv = gen2driv;
  endfunction
  
  //Reset task, Reset the Interface signals to default/initial values
  task reset;
    wait(vif.reset);
    $display("[ DRIVER ] ----- Reset Started -----");
    vif.a <= 0;
    vif.b <= 0;
    vif.valid <= 0;
    wait(!vif.reset);
    $display("[ DRIVER ] ----- Reset Ended   -----");
  endtask
  
  //drivers the transaction items to interface signals
  task main;
    forever begin
      transaction trans;
      gen2driv.get(trans);
      @(posedge vif.clk);
      vif.valid <= 1;
      vif.a     <= trans.a;
      vif.b     <= trans.b;
      @(posedge vif.clk);
      vif.valid <= 0;
      trans.c   <= vif.c;
      @(posedge vif.clk);
      trans.display("[ Driver ]");
      no_transactions++;
    end
  endtask
          
endclass