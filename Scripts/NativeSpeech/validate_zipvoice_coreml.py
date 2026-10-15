"""Fixed-input component parity and audible oracle for the ZipVoice port."""
import argparse
import importlib.util
import json
from pathlib import Path
import coremltools as ct
import numpy as np
import soundfile as sf
import torch
from vocos import Vocos

p = argparse.ArgumentParser()
p.add_argument("checkpoint", type=Path)
p.add_argument("bundle", type=Path)
p.add_argument("vocos", type=Path)
p.add_argument("--text", default="夜风穿过窗棂，书页轻轻翻动。")
a = p.parse_args()
torch.set_num_threads(2)
spec = importlib.util.spec_from_file_location("zipconvert", Path(__file__).with_name("convert_zipvoice_coreml.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.patch_simple_downsample(); model, _ = m.load_model(a.checkpoint)
lexicon = {}
phones = {s.rsplit('\t', 1)[0]: int(s.rsplit('\t', 1)[1]) for s in (a.bundle / "tokens.txt").read_text().splitlines()}
for line in (a.bundle / "lexicon.txt").read_text().splitlines():
    parts = line.split()
    if len(parts)>1 and all(x in phones for x in parts[1:]): lexicon[parts[0]] = [phones[x] for x in parts[1:]]
def encode(text):
    text = text.replace('，', ',').replace('。', '.')
    i = 0; result = []
    while i < len(text):
        if text[i] in ',.!?': result.append(phones[text[i]]); i += 1; continue
        for n in range(min(32,len(text)-i),0,-1):
            if text[i:i+n] in lexicon:
                result += lexicon[text[i:i+n]]; i += n; break
        else: raise ValueError(text[i])
    return result
ref = json.loads((a.bundle / 'reference.json').read_text())
prompt = encode(ref['text']); tokens = prompt + encode(a.text)
count = len(tokens); frames = int(np.ceil(ref['frames'] / len(prompt) * count))
assert frames <= 1024
ti = np.zeros((1,128), dtype=np.int32); ti[0,:count] = tokens
tm = np.ones((1,128), dtype=np.float32); tm[0,:count]=0
text = m.CoreMLTextEncoder(model).eval(); flow = m.CoreMLFmDecoder(model).eval()
te = ct.models.MLModel(str(a.bundle/'TextEncoder.mlpackage'), compute_units=ct.ComputeUnit.CPU_ONLY)
fm = ct.models.MLModel(str(a.bundle/'FmDecoder.mlpackage'), compute_units=ct.ComputeUnit.CPU_ONLY)
report = {'text':a.text, 'frames':frames, 'comparisons':[]}
def compare(name,x,y):
    x=x.flatten().astype(np.float64);y=y.flatten().astype(np.float64)
    cos=float(x@y/np.sqrt((x@x)*(y@y)))
    report['comparisons'].append({'component':name,'cosine':cos,'max_absolute_error':float(np.max(np.abs(x-y)))})
    print(name,cos,flush=True)
    assert np.isfinite(y).all() and cos > .99
with torch.no_grad():
    emb = text(torch.from_numpy(ti),torch.from_numpy(tm)).numpy()
    ce = te.predict({'tokens':ti,'padding_mask':tm})['token_embeds']
    compare('text_encoder',emb[:,:count],ce[:,:count])
    def expand(e):
        out=np.zeros((1,1024,100),np.float32)
        for f in range(frames):out[0,f]=e[0,min(count,f//(frames//count))]
        return out
    cond=expand(emb); ccond=expand(ce)
    speech=np.zeros((1,1024,100),np.float32);speech[0,:ref['frames']]=np.array(ref['features']).reshape(-1,100)
    mask=np.ones((1,1024),np.float32);mask[:,:frames]=0
    rng=np.random.default_rng(20261014);x=rng.standard_normal((1,1024,100)).astype(np.float32);cx=x.copy()
    times=[.5*t/(1-.5*t) for t in np.linspace(0,1,5)]
    for i in range(4):
        t=np.array([times[i]],np.float32);g=np.array([3],np.float32)
        v=flow(*[torch.from_numpy(z) for z in (t,x,cond,speech,g,mask)]).numpy()
        cv=fm.predict({'t':t,'x':cx,'text_condition':ccond,'speech_condition':speech,'guidance_scale':g,'padding_mask':mask})['v']
        compare('flow_step_'+str(i),v[:,:frames],cv[:,:frames])
        x+=v*(times[i+1]-times[i]);cx+=cv*(times[i+1]-times[i])
    vocos=Vocos.from_hparams(str(a.vocos/'config.yaml'));vocos.load_state_dict(torch.load(a.vocos/'pytorch_model.bin',weights_only=True));vocos.eval()
    for name,z in [('torch-oracle',x),('coreml-oracle',cx)]:
        features=torch.from_numpy(z[:,ref['frames']:frames].transpose(0,2,1)/.1)
        audio=vocos.decode(features)[0].numpy()*ref['gain'];sf.write(a.bundle/(name+'.wav'),audio,24000)
(a.bundle/'parity.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
