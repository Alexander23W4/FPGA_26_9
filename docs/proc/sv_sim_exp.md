
## task & function:
1. 核心区别
特性	task	function
是否可以等待时钟	可以	不可以
是否可以使用 @(posedge clk)	可以	不可以
是否可以使用 #10 延时	可以	不可以
是否可以调用 task	可以	不可以调用会消耗时间的 task
返回数据	可以通过 output、inout、ref 等参数返回	可以通过返回值或参数返回
是否适合 TB 驱动事务	非常适合	不适合需要等待握手的事务


