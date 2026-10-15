"""Recover an ordinary FP16 checkpoint from the tested MLX 4-bit CustomVoice.

Offline only. The original 4-bit quantization error is retained; no model or
speaker substitution occurs. Run with the research MLX Python environment.
"""
import argparse
import json
from pathlib import Path
import shutil
import mlx.core as mx

p = argparse.ArgumentParser()
p.add_argument("source", type=Path)
p.add_argument("destination", type=Path)
a = p.parse_args()
a.destination.mkdir(parents=True, exist_ok=True)
weights = mx.load(str(a.source / "model.safetensors"))
recovered = {}
for name, tensor in weights.items():
    if name.endswith((".scales", ".biases")):
        continue
    prefix = name.removesuffix(".weight")
    if name.endswith(".weight") and prefix + ".scales" in weights:
        tensor = mx.dequantize(tensor, weights[prefix + ".scales"],
                               weights[prefix + ".biases"], group_size=64, bits=4)
    recovered[name] = tensor.astype(mx.float16)
    mx.eval(recovered[name])
mx.save_safetensors(str(a.destination / "model.safetensors"), recovered)
config = json.loads((a.source / "config.json").read_text())
config.pop("quantization", None)
config.pop("quantization_config", None)
(a.destination / "config.json").write_text(json.dumps(config, indent=2))
for name in ["vocab.json", "merges.txt", "tokenizer_config.json"]:
    shutil.copyfile(a.source / name, a.destination / name)
shutil.copytree(a.source / "speech_tokenizer", a.destination / "speech_tokenizer", dirs_exist_ok=True)
print("Recovered", len(recovered), "tensors; retained CustomVoice speaker IDs", flush=True)
