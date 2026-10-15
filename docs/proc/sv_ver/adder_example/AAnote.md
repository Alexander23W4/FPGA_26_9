
### 这个例子, 虽然看起来是全链路, 但是仿真最关键的东西: 
### 随机激励生成与其约束, assert断言(SVA)放在那里, coverage覆盖率放在那里在哪里输出, trace和difftest   是一个都没有
### 所以这里单独整理出来

# 随机激励更标准地, 怎么给?
transaction	定义随机数据的合法性	    rand、constraint
generator	产生事务并发送给Driver	    randomize()、随机化失败处理
test	    决定测试策略	           随机多少次、使用哪组约束、是否定向测试

# SVA应该放在那里?
SVA（SystemVerilog Assertions）主要用于检查时序、协议和设计不变量，通常直接写在 interface、独立 checker 模块或 DUT 旁边，再通过实例化或 bind 连接。

property p_valid_to_result;
    @(posedge clk) disable iff (reset)
        valid |=> result_valid;
endproperty

assert property (p_valid_to_result)
    else $error("Result did not become valid");


# Coverage应该在哪里定义, 在哪里输出?
在例子中补充了: 单独用一个类定义, 在仿真所有步骤完成后(post_test)用cg.get_coverage()输出