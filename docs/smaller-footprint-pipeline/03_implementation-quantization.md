# 03 · Implementation — quantization (the on-device int8 trap)

**Status:** ✅ done · **Owns:** the `--image-quant` / `--text-quant` paths in `export_vision_model.py`
**Shipped:** image = **dynamic int8 (MatMul-only)** ~92 MB · text = **fp16** ~129 MB

The single most surprising part of the build: choosing a quantization that is both
**accurate** and **actually loads** on the target runtime. Desktop numerics lie.

## The failure that started it
First device run: the int8 image encoder **failed to load** on Android —
`ORT_NOT_IMPLEMENTED: Could not find an implementation for ConvInteger(10)`.
`flutter_onnxruntime`'s ORT-Android (ARM) build has no `ConvInteger` kernel, even
though desktop ORT (x86) ran the same file fine. And because `isModelLoaded` ANDs
`vision.isLoaded`, a vision-load failure **blocked boot entirely** (the Qwen text
model loaded fine; the app still never went ready).

**Lesson:** validate runtime/op support *on-device*, not just numerics on desktop.

## The options (image encoder)
| Mode | Loads on ARM? | Accuracy | Size | Why |
| --- | --- | --- | --- | --- |
| dynamic int8 (full) | ❌ | good | ~90 MB | emits `ConvInteger` (no ARM kernel) |
| static int8 (QDQ) | ✅ | **destroyed** | ~88 MB | int8 *activations* collapse the 768-d cosine geometry — tiger→"green", parity ≈ 0 |
| **dynamic int8, MatMul-only** ✅ shipped | ✅ **verified** | good (~0.99) | ~92 MB | excludes Conv → only `MatMulInteger`, which the ARM build *does* implement |
| fp16 | ✅ | ~1.000 | ~173 MB | standard `Conv`/`MatMul`+`Cast`; safe but ~2× size |

**Key insight:** dynamic int8 keeps **activations in fp32** (cosine angles survive)
but full dynamic quant emits `ConvInteger`; static int8 uses the mobile-supported
`QLinearConv`/`QLinearMatMul` but **quantises activations**, which destroys a
normalised-embedding model. *No int8 mode is both supported and accurate by default.*

## Solution — exclude the one Conv
The DINOv2 image encoder has exactly **one** Conv (the patch-embed) and ~72
MatMuls. Excluding Conv from dynamic quant (`op_types_to_quantize=["MatMul"]`)
drops `ConvInteger` and emits only `MatMulInteger`. An **on-device A/B test**
(temporary "Vision engine" indicator in Settings → Model info) **confirmed the ARM
build implements `MatMulInteger`** → the ~92 MB int8 image encoder loads and is
accurate (top-1 labels == fp32). The probe + indicator were removed once verified.

## Why the text encoder is fp16, not int8
For the **text** encoder, dynamic int8 is *larger* (~141 MB) than fp16 (~129 MB):
CLIP's 49k-token embedding is a `Gather`, not a `MatMul`, so MatMul-only quant
leaves it **fp32** while fp16 halves it. fp16 is also lossless (parity 1.000) vs
int8 (~0.96). So each encoder gets its best option:
`--image-quant dynamic --text-quant fp16`.

> Earlier (corrected) mistake: an estimate of "~63 MB dynamic text" assumed
> uniform halving; the real number is 141 MB because of the embedding table.

## The fp16 gotcha
`onnxconverter_common`'s float16 converter left mixed-type `Div` nodes that ORT
**rejects at load**. Use **`onnxruntime.transformers`'s** converter instead — it
inserts the casts correctly (validated cosine 1.000), with `keep_io_types=True` so
the Dart side still sends fp32.

## Follow-up (not done)
The AND-gate boot dependency means any future vision failure bricks startup —
consider degrading to a vision-disabled mode instead of blocking boot.
