
SystemVerilog for design is an extension of Verilog-2005
SystemVerilog for verification

# veriations && arr:
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

# assignment && proc_ctrl
Blocking assignment statements execute in series order. Blocking assignment blocks the execution of the next statement until the completion of the current assignment execution.

注意, 阻塞赋值的本质就是顺序赋值, 也会锁存旧值. 如果rtl错误使用阻塞赋值, 就会综合出锁存器


unique if    priority if

while        do while
for          foreach
repeat       forever

break        continue

