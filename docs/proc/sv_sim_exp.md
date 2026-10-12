
## task & function:
1. 核心区别
特性	task	function
是否可以等待时钟	可以	不可以
是否可以使用 @(posedge clk)	可以	不可以
是否可以使用 #10 延时	可以	不可以
是否可以调用 task	可以	不可以调用会消耗时间的 task
返回数据	可以通过 output、inout、ref 等参数返回	可以通过返回值或参数返回
是否适合 TB 驱动事务	非常适合	不适合需要等待握手的事务


名称	类型	用途	示例
$display	系统任务（System Task）	输出信息，自动换行	$display("x=%0d", x);  //
$write	系统任务	输出信息，不自动换行	$write("Hello ");               // 
$monitor	系统任务	监视表达式，发生变化时输出	$monitor("x=%0d", x);
$strobe	系统任务	在当前仿真时间槽的 Postponed 区域输出最终值	$strobe("x=%0d", x);
$time	系统函数（System Function）	返回当前仿真时间，类型为 time	t = $time;  //
$realtime	系统函数	返回当前仿真时间，支持实数形式	t = $realtime;
$itor	系统函数	将整数转换为实数	r = $itor(x);
$rtoi	系统函数	将实数转换为整数，向零截断	x = $rtoi(r);
$finish	系统任务	结束仿真	$finish;
$stop	系统任务	暂停仿真，通常进入交互调试状态	$stop;
$fatal	系统任务	报告致命错误，可终止仿真	$fatal(1, "Error!");   //
$error	系统任务	报告错误，通常不立即终止仿真	$error("Unexpected value");
$warning	系统任务	报告警告	$warning("Warning!");
$info	系统任务	输出信息性诊断消息	$info("Simulation started");
$random	系统函数	生成有符号伪随机整数	x = $random;
$urandom	系统函数	生成 32 位无符号伪随机数	x = $urandom;
$urandom_range	系统函数	在指定范围内生成伪随机数	x = $urandom_range(255, 0);
$clog2	系统函数	计算以 2 为底的对数向上取整，常用于计算位宽	N = $clog2(256);
$bits	系统函数	返回表达式或类型的位数	N = $bits(data);
$countones	系统函数	统计向量中值为 1 的位数	N = $countones(data);
$isunknown	系统函数	检查表达式中是否包含 X 或 Z	if ($isunknown(data)) ...
$onehot	系统函数	检查是否恰好有一位为 1	assert ($onehot(sel));
$onehot0	系统函数	检查至多有一位为 1	assert ($onehot0(sel));
$past	系统函数（断言语境）	获取前一个采样时钟周期的表达式值	assert (a == $past(b));