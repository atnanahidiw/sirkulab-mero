#!/usr/bin/env python3
"""Export the DINOv2-small image encoder for the compare matrix.

This branch is image-only: there is no text encoder and no attribute
embedding asset. The compare artifact is the exported ONNX image encoder plus
its size summary, which is what we need to compare the footprint against the
text-aligned backbones.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

MODEL_ID = "facebook/dinov2-small"
SUFFIX = "dinov2_small"
DISPLAY_NAME = "DINOv2 (ViT-S/14)"
IMAGE_SIZE = 224


def l2(v: np.ndarray) -> np.ndarray:
    return v / (np.linalg.norm(v, axis=-1, keepdims=True) + 1e-9)


def export_onnx(model, out_dir: Path) -> Path:
    import torch

    out_dir.mkdir(parents=True, exist_ok=True)
    image_path = out_dir / f"image_encoder_{SUFFIX}.onnx"

    class ImageHead(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m

        def forward(self, pixel_values):
            out = self.m(pixel_values=pixel_values)
            emb = out.pooler_output if getattr(out, "pooler_output", None) is not None else out.last_hidden_state[:, 0, :]
            return emb / (emb.norm(dim=-1, keepdim=True) + 1e-9)

    dummy = torch.randn(1, 3, IMAGE_SIZE, IMAGE_SIZE)
    torch.onnx.export(
        ImageHead(model).eval(),
        dummy,
        image_path,
        opset_version=17,
        input_names=["pixel_values"],
        output_names=["image_embeds"],
        do_constant_folding=True,
        dynamo=False,
    )
    return image_path


def main() -> int:
    from transformers import AutoImageProcessor, Dinov2Model

    app_repo = Path(__file__).resolve().parents[3]
    scripts_dir = app_repo / "scripts"
    out_dir = app_repo / "assets" / "models"
    compare_dir = scripts_dir / "model_compare" / SUFFIX
    out_dir.mkdir(parents=True, exist_ok=True)
    compare_dir.mkdir(parents=True, exist_ok=True)

    print(f"Loading {DISPLAY_NAME}: {MODEL_ID}")
    processor = AutoImageProcessor.from_pretrained(MODEL_ID, trust_remote_code=True)
    model = Dinov2Model.from_pretrained(MODEL_ID, trust_remote_code=True).eval()

    print(f"[1/2] exporting ONNX for {DISPLAY_NAME} …")
    onnx_path = export_onnx(model, out_dir)
    image_size_mb = onnx_path.stat().st_size / 1e6

    summary = {
        "model_id": MODEL_ID,
        "display_name": DISPLAY_NAME,
        "suffix": SUFFIX,
        "processor_size": getattr(processor, "size", None),
        "onnx_image_mb": round(image_size_mb, 2),
        "onnx_text_mb": None,
        "onnx_total_mb": round(image_size_mb, 2),
        "notes": "image-only backbone; text encoder and zero-shot naming are intentionally omitted",
    }
    summary_json = compare_dir / f"summary_{SUFFIX}.json"
    summary_md = compare_dir / f"summary_{SUFFIX}.md"
    summary_json.write_text(json.dumps(summary, indent=2))
    summary_md.write_text(
        "\n".join(
            [
                f"# {DISPLAY_NAME}",
                "",
                f"- model id: `{MODEL_ID}`",
                f"- image-only ONNX: `{onnx_path.name}` ({image_size_mb:.1f} MB)",
                "- text encoder: n/a",
                "- evaluation metrics: n/a for the image-only compare pass",
            ]
        )
        + "\n"
    )
    (compare_dir / f"vision_eval_{SUFFIX}.jsonl").write_text("")
    print(f"[2/2] wrote {summary_json}, {summary_md} and {onnx_path.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
