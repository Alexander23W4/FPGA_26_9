
module sv1_enum (
    ports
);
/*
enum {IDLE = 0, OPERATE, FEEDBACK} States;

first()	returns the value of the first member of the enumeration
last()	returns the value of the last member of the enumeration
next()	returns the value of next member of the enumeration
next(N)	returns the value of next Nth member of the enumeration
prev()	returns the value of previous member of the enumeration
prev(N)	returns the value of previous Nth member of the enumeration
num()	returns the number of elements in the given enumeration
name()	returns the string representation of the given enumeration value
*/
    enum {RED = 0, YELLOW = 1, BLUE, BLACK} Color;
    string s0 = "Hello World";

    // process begins:
    initial begin
        Color = Color.first

        for (integer i = 0; i < 4; i++ ) begin
            $display("Color :: color of %0s is %0d. ", Color.name, Color);
            Color = Colors.next;
        end
    end
    
endmodule


module sv1_arr (
    ports
);
    
/*
int array1 [6];            //fixed size single dimension array
int array2 [5:0];          //fixed size single dimension array
int array3 [3:0][2:0];     //fixed size multi dimension array
bit [7:0] array4[2:0];     //unpacked array declaration
bit [2:0][7:0] array5;     //packed array declaration
bit [2:0][7:0] array6 [3]; //mixed packed and unpacked array
*/

    bit [7:0] arr1 [3:0];
    bit [7:0][3:0] arr2 [3:0];

    byte arr3 [3:0];
    byte arr4 [5]; // 0-4

/*
The space for a dynamic array doesn’t exist until the array is explicitly created at run-time, 
    space is allocated when new[number] is called. 

new[ ]    –> allocates the storage.
size( )    –> returns the current size of a dynamic array.
delete( ) –> empties the array, resulting in a zero-sized array.
*/

    bit [7:0] arr [];

/*
   bit    queue_1[$];     // queue of bits  (unbound queue)
   int    queue_2[$];     // queue of int  
   byte   queue_3[$:255]; // queue of byte (bounded queue with 256 entries)
   string queue_4[$];     // queue of strings
*/



endmodule