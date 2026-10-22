#!/usr/bin/env python3
"""Restore and verify the pinned native runtime and complete offline model."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "Vendor/SpeechRuntime/runtime-lock.json"

def normalize_ios_framework_metadata(destination):
    """Match the deployment target used when Xcode links the static ORT framework.

    The upstream plist says 15.1, but Xcode's generated dynamic wrapper targets
    iOS 26. Leaving the upstream value causes App Store error 90208.
    """
    for path in destination.glob("*/onnxruntime.framework/Info.plist"):
        info = plistlib.loads(path.read_bytes())
        info["MinimumOSVersion"] = "26.0"
        path.write_bytes(plistlib.dumps(info, sort_keys=False))

def checksum(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()

def verify(manifest):
    failed = []
    for name, expected in manifest["files"].items():
        path = ROOT / name
        if not path.is_file() or checksum(path) != expected:
            failed.append(name)
    if failed:
        raise RuntimeError("Missing or changed offline files:\n" + "\n".join(failed))
    print(f"Verified {len(manifest['files'])} offline model/runtime files.")

def install(manifest):
    cache = ROOT / "build/SpeechResearch"
    cache.mkdir(parents=True, exist_ok=True)
    for artifact in manifest["artifacts"]:
        archive = cache / artifact["file"]
        if not archive.exists() or checksum(archive) != artifact["sha256"]:
            partial = archive.with_suffix(archive.suffix + ".part")
            subprocess.run(["curl", "--fail", "--location", "--retry", "4", "--connect-timeout", "15", "--output", str(partial), artifact["url"]], check=True)
            if checksum(partial) != artifact["sha256"]:
                raise RuntimeError("Downloaded checksum mismatch: " + artifact["file"])
            partial.replace(archive)
        with tempfile.TemporaryDirectory(prefix="speech-") as temporary:
            extracted = Path(temporary)
            if artifact["kind"] == "framework":
                # zipfile.extractall does not preserve macOS framework symlinks.
                subprocess.run(["ditto", "-xk", str(archive), temporary], check=True)
                source = next(extracted.glob("*.xcframework"))
                destination = ROOT / "Vendor/SpeechRuntime/Frameworks" / (artifact["destination"] + ".xcframework")
                if destination.exists(): shutil.rmtree(destination)
                shutil.copytree(source, destination, symlinks=True)
                if artifact["destination"] == "ORTIOS":
                    normalize_ios_framework_metadata(destination)
            elif artifact["kind"] == "raw":
                destination = ROOT / artifact["destination"]
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(archive, destination)
            elif artifact["kind"] == "voice":
                # 只恢复选定男声及中文前端文件，不覆盖其他音色的模型文件。
                subprocess.run(["tar", "xjf", str(archive), "-C", temporary], check=True)
                source = extracted / artifact["subdirectory"]
                destination = ROOT / artifact["destination"]
                destination.mkdir(parents=True, exist_ok=True)
                for upstream, local in artifact["selectedFiles"].items():
                    shutil.copy2(source / upstream, destination / local)
    verify(manifest)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true", help="Restore from checksum-pinned upstream archives")
    parser.add_argument("--verify", action="store_true", help="Verify only; never download")
    arguments = parser.parse_args()
    manifest = json.loads(LOCK.read_text())
    if arguments.install: install(manifest)
    else: verify(manifest)
