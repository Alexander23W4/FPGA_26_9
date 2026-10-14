

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

  sequence seq_1;
    @(posedge clk) a == 1;
  endsequence

  assert property (seq_1);

  property p1;
    @(posedge clk) a == 1;
  endproperty

  assert property (p1);


  sequence seq;
    a || b;
  endsequence

  sequence seq1;
    c == 0;
  endsequence

  // 错误写法
  // property p;
  //   @(posedge clk);
  //   !a |-> seq;
  //   seq1;
  // endproperty

  property p;
    @(posedge clk)
      (!a |-> seq) and seq1;
  endproperty


  assert property (p);


  /*
  运算符	含义	a 为真时，要求 b
  \|->	Overlapped implication	同一拍为真
  \|=>	Non-overlapped implication	下一拍为真
  */

  // 一个示例.    这么复杂真的很没必要, 直接一个property
  sequence seq_1;
    (a && b) ##1 c;
  endsequence

  sequence seq_2;
    ##2 !d;
  endsequence

  property p;
    @(posedge clk)
      seq_1 |-> seq_2;
  endproperty

  assert property (p);

  property p1;
    @(posedge clk)
        // (a && b) |-> ##1 c |-> ##2 !d;  错误写法
        (a && b) |-> ##1 c ##2 !d;    // 这样写才和p等效
  endproperty

  assert property(p1);


endmodule

