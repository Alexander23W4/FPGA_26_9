
SystemVerilog for design is an extension of Verilog-2005
SystemVerilog for verification

## SV的地位
SV就是为 verilog 的 rtl仿真 服务的
本质上就是一个兼容verilog写法, C++语言(高级语言)思想, 再融合时序控制的  标准语言

保留verilog的基本写法                   [仿真器直接连接RTL]
逻辑语言的基本要素: 变量与计算 流控       [非常丰富]
作为硬件控制的要素: 时序控制              [#n]
具有高级语言的要素: class                [面向对象]

## SV仿真的关注重点:
给DUT提供流式tb(initial), 观察输出

怎么样能够更好的提供 更充分的tb
怎么样输出trace, 集成difftest, 选择合适的信号观察波形

# +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-

# veriations && arr:   变量与计算
wire reg  integer real time

类型	位宽	默认有符号性	能表示的数值范围
bit	1 bit	无符号	0～1
bit [31:0]	32 bit	无符号	0～\(2^{32}-1\)
byte	8 bit	有符号	-128～127
shortint	16 bit	有符号	\(-2^{15}\)～\(2^{15}-1\)
int	32 bit	有符号	\(-2^{31}\)～\(2^{31}-1\)
longint	64 bit	有符号	\(-2^{63}\)～\(2^{63}-1\)

event

typedef 


enum {IDLE = 0, OPERATE, FEEDBACK} States;

first()	returns the value of the first member of the enumeration
last()	returns the value of the last member of the enumeration
next()	returns the value of next member of the enumeration
next(N)	returns the value of next Nth member of the enumeration
prev()	returns the value of previous member of the enumeration
prev(N)	returns the value of previous Nth member of the enumeration
num()	returns the number of elements in the given enumeration
name()	returns the string representation of the given enumeration value

array 
queue

# assignment && proc_ctrl:  流控
Blocking assignment statements execute in series order. Blocking assignment blocks the execution of the next statement until the completion of the current assignment execution.

注意, 阻塞赋值的本质就是顺序赋值, 也会锁存旧值. 如果rtl错误使用阻塞赋值, 就会综合出锁存器


unique if    priority if

while        do while
for          foreach
repeat       forever

break        continue

# "@ #":  时序控制

# +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-

## 对仿真有帮助的feature, tb端, monitor端

## --> tb端:

# randomization

1. 产生随机数  randomize

随机事件控制   rand_mode   pre_randomize

2. 随机约束 (所有约束共同决定合法解的集合, 定义先后不决定优先级)

随机数范围约束  constraint   +   条件约束   生成有规律的随机数列

随机数dist(控制随机权重) 

随机约束   :: 可以禁用, 可以static, 可以inline, 可以设置成软约束, 可以unique约束

所有约束共同决定合法解的集合

