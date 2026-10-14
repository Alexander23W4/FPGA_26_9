

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
    virtual axi_lite_write axr;  // 这边用一个 虚拟接口 用new函数把真正连到DUT的接口取过来给虚拟接口, 在driver里面驱动虚拟接口

    mailbox #(axi_packet) mb;

    function new (mailbox #(axi_packet) mb, axi_lite_write axr);
      this.mb = mb;
      this.axr = axr;
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

  axi_lite_write axr;   // 实际连到DUT的接口

  initial begin
    mailbox #(axi_packet) mb = new();

    generator gen = new(mb);
    driver dr = new(mb, axr);  // 传实际接口给driver

    fork    // 这样写, generator和driver完全并行, 中间mailbox充当queue的传递作用
      repeat(10) begin
        gen.run();
      end

      repeat(10) begin
        dr.send();
      end
    join

  end


endmodule


// 用event进行流程先后的准确控制, 适合需要 明确先后顺序 的 激励流场景
module ev_test;
  event ev;

  initial begin
    -> ev;
    @(ev);    // 不会触发
    $display("received");
  end

  event ev1;

  initial begin
    -> ev1;
    #10;
    fork
      begin
        repeat(5) begin
          #5;
          ->ev1;
        end
      end

      begin
        wait(ev1.triggered);    // 会在#15, 20, 25...触发display   wait 能观察到当前仿真时间槽内事件已经触发的状态
        $display("ev1 is triggered");
      end
    join
  end

  event ev2, ev3;

  initial begin
    fork
      begin
        #5;
        ->ev2;
        #5;
        ->ev3;
      end
      begin
        wait_order(ev2, ev3) else $display("error");
      end
    join
  end

  // 时钟块, 在上升沿之前#1读, 之后#2写 (避免和DUT同时读写, 造成不符合预期的仿真行为)
  clocking cb @(posedge clk);
    default input #1 output #2;
    input  from_Dut;
    output to_Dut;
  endclocking

endmodule 


interface add_if;
  logic [7:0] a;
  logic [7:0] b;
  logic [7:0] result;
endinterface


module test;
  class packet;
    int a;
    int b;

    constraint add_range{    // ★★★
      a < 8'h7f;
      b < 8'h7f;
    }
  endclass

  class generator;  // 建一个packet, 建一个mbx   用packet randomize/赋予 数据, 用mbx.put传出去 
    mailbox mbx;
    packet pkt;

    function new(mailbox mbx);
      this.mbx = mbx;
    endfunction 

    task run;
      pkt = new();
      if(pkt.randomize()) begin      // ★★★
        mbx.put(pkt);         // ★★★
      end else begin
        $fatal("error randomization");
      end
    endtask
  endclass

  class driver;
    mailbox mbx;   // 创建用于接收generator数据的mbx
    virtual add_if aif;    // 接收实际连接DUT的接口
    packet pkt;

    function new(mailbox mbx, add_if aif);
      this.mbx = mbx;
      this.aif = aif;

      assert(aif.result == (aif.a + aif.b));
    endfunction 

    task send;
      mbx.get(pkt);   // ★★★
      aif.a = pkt.a;  // ★★★ ↓
      aif.b = pkt.b;
    endtask
  endclass

 // 实际 interface, 接到DUT
  add_if aif;

  initial begin
    // mailbox
    mailbox mbx
    mbx = new();

    generator gen = new(mbx);
    driver dr = new(mbx);

    // 生成并发送1000组随机数据
    fork
      repeat(1000) begin
        gen.run();   // 生成1000
      end

      repeat(1000) begin
        dr.send();   // 发送1000
      end

      // assert(aif.result == (aif.a + aif.b));

    join

  end

  // 并发断言 concurrent assert  ★: 时序断言  
  property req_gets_ack;
    @(posedge clk)
      req |-> ##[1:3] ack;
  endproperty

  assert property (req_gets_ack);

/*
  含义：
  - 当 req 在某个上升沿采样为 1 时，启动检查。
  - ack 必须在之后第 1、2 或第 3 个上升沿中的至少一个采样为 1。
  - 如果三个周期内都没有 ack，断言失败。
*/


endmodule

/*
时序断言的标准:

sequence  一段时序, 时序表达式
property  定义需要验证的规则, 可包含时序表达式
assert    断言时序规则
*/
module sva;
  property req_gets_ack;
    @(posedge clk)
      req |-> ##[1:3] ack;
  endproperty

  assert_req_gets_ack:
    assert property (req_gets_ack)
    else $error("ACK timeout");



  sequence req_then_ack;
    req ##1 ack;  
  endsequence

  property p1;
    @(posedge clk) req |-> ##1 ack;
  endproperty

  property p2;
    @(posedge clk) start |-> req_then_ack;
  endproperty

  assert property (p1);
  assert property (p2);

endmodule







