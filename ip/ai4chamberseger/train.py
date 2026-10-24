import torch
import torch.nn as nn
import torch.optim as optim
import segmentation_models_pytorch as smp
from torch.utils.data import Dataset, DataLoader
import numpy as np
from PIL import Image
import os
import torchvision.transforms.functional as TF

# 数据集路径
img_dir = r"E:\pld\python\unet\dataset\multi_train\images"
mask_dir = r"E:\pld\python\unet\dataset\multi_train\masks"

class MultiDataset(Dataset):
    def __init__(self, img_dir, mask_dir):
        self.img_dir, self.mask_dir = img_dir, mask_dir
        self.files = os.listdir(img_dir)
    def __len__(self): return len(self.files)
    def __getitem__(self, idx):
        img = Image.open(os.path.join(self.img_dir, self.files[idx])).convert('L')
        mask = Image.open(os.path.join(self.mask_dir, self.files[idx])).convert('L')
        img = TF.resize(img, [256, 256])
        mask = TF.resize(mask, [256, 256], interpolation=TF.InterpolationMode.NEAREST)
        img_np = np.array(img, dtype=np.float32) / 255.0
        mask_np = np.clip(np.round(np.array(mask, dtype=np.float32)), 0, 4).astype(np.int64)
        return torch.from_numpy(img_np).unsqueeze(0), torch.from_numpy(mask_np)

dataset = MultiDataset(img_dir, mask_dir)
dataloader = DataLoader(dataset, batch_size=16, shuffle=True)
device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

model = smp.Unet(encoder_name="mobilenet_v2", encoder_weights=None, in_channels=1, classes=5).to(device)
criterion = nn.CrossEntropyLoss()
optimizer = optim.AdamW(model.parameters(), lr=0.001)

print("🚀 开始训练...")
for epoch in range(10): # 跑10轮
    model.train()
    epoch_loss = 0
    for imgs, masks in dataloader:
        imgs, masks = imgs.to(device), masks.to(device)
        optimizer.zero_grad()
        loss = criterion(model(imgs), masks)
        loss.backward()
        optimizer.step()
        epoch_loss += loss.item()
    print(f"Epoch [{epoch+1}/10], Loss: {epoch_loss/len(dataloader):.4f}")

print("🎉 训练完成！保存权重中...")

# 保存给 PyTorch 测试用的 .pth 文件
torch.save(model.state_dict(), r"E:\pld\python\model.pth")

# 保存给 FPGA HLS 用的 .h 文件
with open(r"E:\pld\python\weights.h", "w") as f:
    f.write("#include <stdint.h>\n")
    for name, param in model.state_dict().items():
        data = param.cpu().detach().numpy().flatten()
        f.write(f"const float {name.replace('.', '_')}[] = {{")
        f.write(", ".join([f"{x:.6f}" for x in data]))
        f.write("};\n")

print("✅ 模型已保存至 E:\pld\python\model.pth")
print("✅ 权重已导出至 E:\pld\python\weights.h")