
# threshold debug
bug: 怀疑 threshold 代码修正过后, 并不能实现register ctrl的逻辑

验证:  
0x08 应该能够在任何情况下成功写入 
发0x04 = 1, ts 应该使用 
发0x04 = 0, ts 应该恢复自动产生threshold


1. 首先验证reg有没有变化
2. 其次验证功能有没有实现