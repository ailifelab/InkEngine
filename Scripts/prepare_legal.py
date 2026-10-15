#!/usr/bin/env python3
"""Build/check offline acknowledgments from the reviewed source/license inventory.

This validates local notices. It does not grant rights or certify App Store
compatibility, a complete SBOM, or corresponding-source reproducibility.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / 'Vendor/SpeechRuntime/distribution-licenses.json'
OUTPUT = ROOT / 'App/Resources/Legal/third-party-notices.md'


def render():
    registry = json.loads(REGISTRY.read_text())
    sections = ['# 开源许可与第三方声明',
                '墨语引擎原创源码采用 GPL-3.0-or-later。第三方组件保留其原有版权和许可。下列许可文本不改变各组件的授权范围，也不替代源码分发义务。',
                '项目源码与构建说明：https://github.com/ailifelab/InkEngine',
                '## 组件与来源']
    texts = {'LICENSE': (ROOT / 'LICENSE').read_text()}
    for component in registry['components']:
        paths = []
        for item in component['licenseFiles']:
            path = ROOT / item['path']
            data = path.read_bytes()
            if hashlib.sha256(data).hexdigest() != item['sha256']:
                raise ValueError(f"License checksum changed: {item['path']}")
            texts[item['path']] = data.decode('utf-8')
            paths.append(item['path'])
        sections.append(f"{component['name']} — {component['declaredLicense']}\n\n来源：{component['source']}\n\n版本：{component['revision']}\n\n许可文件：" + '、'.join(paths))
        if component.get('modifications'):
            sections.append('本项目改动：' + component['modifications'])
    sections.append('## 完整许可文本')
    seen = set()
    for name, content in texts.items():
        digest = hashlib.sha256(content.encode()).hexdigest()
        if digest in seen:
            continue
        seen.add(digest)
        sections.append('## ' + name)
        if name.endswith('onnxruntime-ThirdPartyNotices.txt'):
            sections.append('以下为该 ONNX Runtime 版本的原始上游通知汇编，覆盖多种可选平台与构建配置；不表示其中每个组件均已链接到本应用，也不替代最终二进制依赖核对。原文保持不变。')
        sections.append(content.rstrip())
    return '\n\n'.join(sections) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Check without changing files')
    args = parser.parse_args()
    try:
        expected = render()
        if args.check:
            if not OUTPUT.is_file() or OUTPUT.read_text() != expected:
                raise ValueError('Offline legal notice is stale; run python3 Scripts/prepare_legal.py')
            print('Offline license texts and inventory checksums verified; no additional authorization is implied.')
        else:
            OUTPUT.write_text(expected)
            print('Generated App/Resources/Legal/third-party-notices.md')
    except (OSError, ValueError, KeyError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
