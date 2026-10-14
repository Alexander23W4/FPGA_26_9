

module IPC;

    semaphore sema;    // 信号量

    initial begin
        sema = new(1);

      // 这里example 是经典的 fork并行 + semaphore模拟资源有限的情况
        fork    // 这里同时创建了两个进程  fork...join 是 SystemVerilog 中用于并行启动多个进程，并等待它们全部结束
            display();
            display();
        join
    end

    task automatic display();
        sema.get();

        $display($time, "\tCurrent Simulation Time");

        #30;

        sema.put();
    endtask

    task automatic pdisplay();
      $display($time, "\tCurrent Simulation Time");
      #30;
    endtask

    initial begin   // 普通这么写, 就是默认的顺序实行, #0打印一次, #30打印一次
      pdisplay();
      pdisplay();
    end

    initial begin
      fork
        pdisplay();
        pdisplay();
      join
    end


  initial begin
    sema=new(4); //creating sema with '4' keys

    fork
      display(2); //process-1
      display(3); //process-2
      display(2); //process-3
      display(1); //process-4
    join
  end

  //display method
  task automatic display(int key);
    sema.get(key);     // 如果没有get成功, 就会阻塞在这条
    $display($time,"\tCurrent Simulation Time, Got %0d keys",key);
    #30;
    sema.put(key); 
  endtask


endmodule


interface axi_lite_write;
    logic [15:0] awaddr;
    logic        awvalid;
    logic        awready;

    logic [15:0] wdata;
    logic [1:0]  wstrb;
    logic        wvalid;
    logic        wready;

    logic [1:0]  bresp;
    logic        bvalid;
    logic        bready;
endinterface //axi_lite_read

module test;

  class axi_test;
    rand bit [15:0] awaddr;
    rand bit [15:0] wdata;

    constraint awaddr_range {
      awaddr[1:0] = 2'b00;
      awaddr inside {[16'h0000: 16'h3fff]};
    }

  endclass

  axi_lite_write axr;
  semaphore sema;

  initial begin
    axi_test tp;
    tp = new();  

    sema = new(1);

    // fork    // 这个是在示范一种会导致ub的多驱动错误写法 (如果不加sema)
    //   if(tp.randomize()) begin
    //     send(tp.awaddr, tp.wdata, 1);
    //   end
    
    //   if(tp.randomize()) begin
    //     send(tp.awaddr, tp.wdata, 1);
    //   end
    // join

  end

  initial begin
    axi_test tp1;
    axi_test tp2;
    tp1 = new();
    tp2 = new();

    sema = new(1);

    fork
      if(tp1.randomize()) begin   // ↑ generator 创建并随机化 packet
        send(tp1.awaddr, tp1.wdata, 1);   // driver
      end else begin
        $fatal("randomization error");
      end
      if(tp2.randomize()) begin
        send(tp2.awaddr, tp2.wdata, 1);
      end else begin
        $fatal("randomization error");
      end
    join
  end

  task send(bit [15:0] addr, bit [15:0] data, int key_req);
    sema.get(key_req);

    bit aw_done;
    bit w_done;

    aw_done = 0;
    w_done = 0;

    @(negedge clk);
    axr.awaddr = addr;
    axr.awvalid = 1;
    axr.wvalid = 1;
    axr.wstrb = 2'b11;
    axr.wdata = data;

    while(!(aw_done && w_done)) begin
      @(posedge clk);
      if(axr.awready) aw_done = 1;
      if(axr.wready) w_done = 1;

      @(negedge clk);
      if(aw_done) axr.awvalid = 0;
      if(w_done) axr.wvalid = 0;
    end

    @(negedge clk);
    axr.bready = 1;

    while(!(axr.bvalid && axr.bready)) begin   // 满足条件, 则说明上个上升沿已经完成握手, 可以退出
      @(posedge clk);   // 推上升沿
    end

    @(negedge clk);
    axr.bready = 0;

    sema.put(key_req);
  endtask


endmodule

/*
Generator
创建 transaction 对象，随机化地址和数据

Mailbox
缓存 transaction，协调 put() 和 get()

Driver
取出 transaction，驱动 AXI-Lite，等待写响应

DUT


这里的关键是：generator 不再调用 send()，
而是把 transaction 放进 mailbox；driver 自己从 mailbox 取出 transaction，再调用 AXI 驱动逻辑。
*/

module test;

  class axi_packet;
    rand bit [15:0] awaddr;
    rand bit [15:0] wdata;

    constraint awaddr_range {
      awaddr[1:0] == 2'b00;
      awaddr inside {[16'h0000: 16'h3fff]};
    }

  endclass

  class generator;
  
    mailbox #(axi_packet) mb;
    axi_packet pkt;

    function new (mailbox #(axi_packet) mb);   // 初始化generator object的时候传递mb
      this.mb = mb;
    endfunction

    // 产生随机axi_packet值, 并传递给mailbox
    task run;
      pkt = new();
      if(pkt.randomize()) begin
        mb.put(pkt);            // 
      end else begin
        $fatal(1, "tandomization error");
      end
    endtask

  endclass

  class driver;   // 从mb中取pkt, 然后send
    axi_packet pkt;
    mailbox #(axi_packet) mb;

    function new (mailbox #(axi_packet) mb);
      this.mb = mb;
    endfunction

    task send;
      mb.get(pkt);
      bit aw_done;
      bit w_done;

      aw_done = 0;
      w_done = 0;

      @(negedge clk);
      axr.awaddr = pkt.awaddr;
      axr.awvalid = 1;
      axr.wvalid = 1;
      axr.wstrb = 2'b11;
      axr.wdata = pkt.wdata;

      while(!(aw_done && w_done)) begin
        @(posedge clk);
        if(axr.awready) aw_done = 1;
        if(axr.wready) w_done = 1;

        @(negedge clk);
        if(aw_done) axr.awvalid = 0;
        if(w_done) axr.wvalid = 0;
      end

      @(negedge clk);
      axr.bready = 1;

      while(!(axr.bvalid && axr.bready)) begin   // 满足条件, 则说明上个上升沿已经完成握手, 可以退出
        @(posedge clk);   // 推上升沿
      end

      @(negedge clk);
      axr.bready = 0;

    endtask

  endclass

  axi_lite_write axr;

  initial begin
    mailbox #(axi_packet) mb = new();

    generator gen = new(mb);
    driver dr = new(mb);

    fork
      repeat(10) begin
        gen.run();
        dr.send();
      end
    join

  end


endmodule

