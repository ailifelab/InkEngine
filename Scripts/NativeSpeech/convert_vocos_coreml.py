"""Local Vocos 24 kHz Core ML export, with native Accelerate ISTFT fixtures.

The neural network returns real/imaginary spectra. The app reconstructs PCM
with Apple's FFT and overlap-add; no Python or ONNX is needed at runtime.
"""
import argparse
import json
from pathlib import Path
import shutil
import coremltools as ct
import numpy as np
import soundfile as sf
import torch
from vocos import Vocos

p = argparse.ArgumentParser()
p.add_argument("checkpoint", type=Path)
p.add_argument("output", type=Path)
p.add_argument("--reference", type=Path, required=True)
p.add_argument("--reference-text", default="大家好，请放松心情。")
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
torch.set_num_threads(2)
vocos = Vocos.from_hparams(str(a.checkpoint / "config.yaml"))
vocos.load_state_dict(torch.load(a.checkpoint / "pytorch_model.bin", weights_only=True))
vocos.eval()

class Spectrum(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.backbone = vocos.backbone
        self.out = vocos.head.out
    def forward(self, features):
        x = self.out(self.backbone(features)).transpose(1, 2)
        logmag, phase = x.chunk(2, dim=1)
        mag = torch.exp(logmag).clamp(max=100)
        return mag * torch.cos(phase), mag * torch.sin(phase)

with torch.no_grad():
    wrapper = Spectrum().eval()
    features = torch.randn(1, 100, 8)
    real, imag = wrapper(features)
    expected = vocos.decode(features)
    actual = torch.istft(torch.complex(real, imag), 1024, 256, 1024, torch.hann_window(1024), center=True)
    torch.testing.assert_close(actual, expected, atol=1e-5, rtol=1e-5)
    fixture = {"frames": 8, "real": real.flatten().tolist(), "imag": imag.flatten().tolist(), "samples": expected.flatten().tolist()}
    (a.output / "istft-fixture.json").write_text(json.dumps(fixture))
    traced = torch.jit.trace(wrapper, (features,))
    ml = ct.convert(traced, inputs=[ct.TensorType(name="features", shape=(1, 100, ct.RangeDim(2, 1024, default=8)))],
                    outputs=[ct.TensorType(name="real", dtype=np.float32), ct.TensorType(name="imag", dtype=np.float32)],
                    minimum_deployment_target=ct.target.iOS18, compute_precision=ct.precision.FLOAT16,
                    compute_units=ct.ComputeUnit.CPU_ONLY, skip_model_load=True)
    ml.save(str(a.output / "Vocos.mlpackage"))
    # Store conditioning features once, rather than running another model for
    # the same bundled synthetic voice on every narration request.
    audio, rate = sf.read(a.reference, dtype="float32")
    assert rate == 24000 and audio.ndim == 1
    rms = float(np.sqrt(np.mean(audio ** 2)))
    if rms < 0.1:
        audio *= 0.1 / rms
    mel = vocos.feature_extractor(torch.from_numpy(audio)[None]) * 0.1
    # ZipVoice VocosFbank trims centered STFT to duration rounded to hop size.
    # A centered spectrogram may otherwise keep one extra reference frame.
    reference_frames = (len(audio) + 128) // 256
    mel = mel[..., :reference_frames]
    (a.output / "reference.json").write_text(json.dumps({"text": a.reference_text, "frames": mel.shape[2], "features": mel.transpose(1, 2).flatten().tolist(), "gain": min(1, rms / 0.1)}))
    for name in ["Vocos", "TextEncoder", "FmDecoder"]:
        source = a.output / (name + ".mlpackage")
        if source.exists():
            compiled = Path(ct.utils.compile_model(str(source)))
            destination = a.output / (name + ".mlmodelc")
            if destination.exists(): shutil.rmtree(destination)
            shutil.move(str(compiled), destination)
print("Vocos spectrum and reference exported; PyTorch ISTFT parity passed")
