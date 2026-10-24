import torch
import numpy as np
import os

# 1. 加载你训练好的模型权重
model_path = r"E:\pld\python\model.pth"
state_dict = torch.load(model_path)

# 2. 把它转成 INT8 格式的 C++ 头文件
with open(r"E:\pld\python\weights_int8.h", "w") as f:
    f.write("#include <stdint.h>\n")
    for name, param in state_dict.items():
        if 'num_batches_tracked' in name: continue # 跳过无关参数
        
        # 获取浮点权重
        data = param.cpu().detach().numpy().flatten()
        
        # 核心转换：乘 128 并四舍五入，转成 8 位整数
        int8_data = np.clip(np.round(data * 128), -128, 127).astype(np.int8)
        
        # 写入 C++ 数组
        var_name = name.replace('.', '_')
        f.write(f"const int8_t {var_name}[] = {{")
        f.write(",".join([str(x) for x in int8_data]))
        f.write("};\n")

print("✅ 权重已成功量化为 int8 格式，保存为 weights_int8.h")