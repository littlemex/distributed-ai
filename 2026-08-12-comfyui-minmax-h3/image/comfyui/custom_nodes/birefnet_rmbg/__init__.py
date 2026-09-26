"""BiRefNet background removal as a ComfyUI node.

Node "BiRefNetRemoveBackground": IMAGE -> (IMAGE, MASK). Feed both into the core node
JoinImageWithAlpha to get an RGBA image that SaveImage writes as a transparent PNG.

Weights: ZhengPeng7/BiRefNet (MIT), loaded from models/birefnet/ (fetched by the model-fetch Job),
falling back to the Hugging Face Hub when that folder is empty.
"""
import os

import torch
import torch.nn.functional as F

import folder_paths

_MODEL = {}
_DIR = os.path.join(folder_paths.models_dir, "birefnet")
_MEAN = torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1)
_STD = torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1)


def _load(device):
    if "m" not in _MODEL:
        from transformers import AutoModelForImageSegmentation
        src = _DIR if os.path.exists(os.path.join(_DIR, "config.json")) else "ZhengPeng7/BiRefNet"
        m = AutoModelForImageSegmentation.from_pretrained(src, trust_remote_code=True)
        _MODEL["m"] = m.eval().to(device).half() if device.type == "cuda" else m.eval().to(device)
    return _MODEL["m"]


class BiRefNetRemoveBackground:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"image": ("IMAGE",), "resolution": ("INT", {"default": 1024, "min": 512, "max": 2048, "step": 64})}}

    RETURN_TYPES = ("IMAGE", "MASK")
    FUNCTION = "run"
    CATEGORY = "image/mask"

    def run(self, image, resolution):
        device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        model = _load(device)
        b, h, w, _ = image.shape
        x = image.permute(0, 3, 1, 2)
        x = F.interpolate(x, size=(resolution, resolution), mode="bilinear", align_corners=False)
        x = ((x - _MEAN) / _STD).to(device)
        with torch.no_grad():
            pred = model(x.half() if device.type == "cuda" else x)[-1].sigmoid().float()
        mask = F.interpolate(pred, size=(h, w), mode="bilinear", align_corners=False)[:, 0].cpu()
        # JoinImageWithAlpha expects a "transparency" mask: 1 = transparent.
        return (image, 1.0 - mask)


NODE_CLASS_MAPPINGS = {"BiRefNetRemoveBackground": BiRefNetRemoveBackground}
NODE_DISPLAY_NAME_MAPPINGS = {"BiRefNetRemoveBackground": "Remove Background (BiRefNet)"}
