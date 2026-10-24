import torch
import numpy as np
from PIL import Image
import os
import matplotlib.pyplot as plt
import torchvision.transforms.functional as TF
import segmentation_models_pytorch as smp

img_dir = r"E:\pld\python\unet\dataset\multi_train\images"
mask_dir = r"E:\pld\python\unet\dataset\multi_train\masks"

device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
model = smp.Unet(encoder_name="mobilenet_v2", encoder_weights=None, in_channels=1, classes=5).to(device)

# 【核心】：把刚才训练好并存下来的 .pth 权重加载进来
# （注意：刚才的 train.py 只导出了 .h，我需要你确认一下有没有存 .pth。如果没有，下面这行可能会报错）
try:
    model.load_state_dict(torch.load(r"E:\pld\python\model.pth"))
    print("✅ 成功加载了训练好的权重！")
except Exception as e:
    print(f"❌ 找不到权重文件: {e}")

model.eval()
files = os.listdir(img_dir)

# 过滤掉医生没画标注的全黑图
valid_files = []
for f in files:
    m = np.array(Image.open(os.path.join(mask_dir, f)))
    if np.max(m) > 0: 
        valid_files.append(f)

if len(valid_files) >= 3:
    random_files = np.random.choice(valid_files, 3, replace=False)
else:
    print("数据集里没有带标注的图！")
    exit()

colors = np.array([[0,0,0], [255,0,0], [0,255,0], [0,0,255], [255,255,0]], dtype=np.uint8)
plt.figure(figsize=(15, 10))

for i, f in enumerate(random_files):
    img = Image.open(os.path.join(img_dir, f)).convert('L')
    mask = Image.open(os.path.join(mask_dir, f)).convert('L')
    img_resized = TF.resize(img, [256, 256])
    mask_resized = TF.resize(mask, [256, 256], interpolation=TF.InterpolationMode.NEAREST)
    
    img_np = np.array(img_resized, dtype=np.float32) / 255.0
    mask_np = np.clip(np.round(np.array(mask_resized, dtype=np.float32)), 0, 4).astype(np.int64)
    
    with torch.no_grad():
        input_t = torch.from_numpy(img_np).unsqueeze(0).unsqueeze(0).to(device)
        logits = model(input_t)
        pred_mask = torch.argmax(logits, dim=1).cpu().squeeze().numpy()
    
    plt.subplot(3, 3, i*3 + 1)
    plt.imshow(img_np, cmap="gray")
    plt.title("Original")
    plt.axis('off')
    
    plt.subplot(3, 3, i*3 + 2)
    plt.imshow(colors[mask_np])
    plt.title("Doctor's Label")
    plt.axis('off')
    
    plt.subplot(3, 3, i*3 + 3)
    plt.imshow(colors[pred_mask])
    plt.title("AI Prediction (Loaded)")
    plt.axis('off')

plt.tight_layout()
plt.show()