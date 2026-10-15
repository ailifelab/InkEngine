#!/usr/bin/env python3
"""Reusable local iOS Release packaging, signature inspection and installation.

Xcode 26+ and an existing signing team are required. No App Store upload.
Copy this file and Config/IPA.json to another project and adjust that config.
"""
import argparse
from datetime import datetime, timedelta, timezone
import fnmatch
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

UTC = timezone.utc
CONFIG_DIRECTORY = Path(__file__).resolve().parents[1] / "Config"
# Personal team/settings stay in an ignored local override.
DEFAULT_CONFIG = CONFIG_DIRECTORY / ("IPA.local.json" if (CONFIG_DIRECTORY / "IPA.local.json").is_file() else "IPA.json")
ENV = dict(os.environ)
ENV.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")


def run(command, log=None):
    command = [str(item) for item in command]
    if log:
        with log.open("wb") as stream:
            result = subprocess.run(command, env=ENV, stdout=stream, stderr=subprocess.STDOUT)
        output = b""
        detail = log.read_bytes()[-10000:].decode(errors="replace") if result.returncode else ""
    else:
        result = subprocess.run(command, env=ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        output = result.stdout
        detail = (result.stdout + result.stderr).decode(errors="replace")[-10000:]
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {command[0]}\n{detail}")
    return output


def digest(file):
    result = hashlib.sha256()
    with file.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def timestamp(value):
    return value.replace(tzinfo=UTC).isoformat() if value.tzinfo is None else value.astimezone(UTC).isoformat()


def inspect_app(app, expected_team=None, expected_bundle=None, renew_days=30):
    run(["codesign", "--verify", "--deep", "--strict", app])
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if expected_bundle and info["CFBundleIdentifier"] != expected_bundle:
        raise RuntimeError("Unexpected application bundle identifier")
    if info.get("DTPlatformName") != "iphoneos":
        raise RuntimeError("Only physical iOS/iPadOS apps can be packaged")
    architectures = run(["lipo", "-archs", app / info["CFBundleExecutable"]]).decode().split()
    if "arm64" not in architectures:
        raise RuntimeError("The app does not contain a physical-device arm64 executable")
    signed_bundles = [app] + sorted(app.rglob("*.appex")) + sorted(app.rglob("*.app"))
    profiles = []
    all_devices = None
    for bundle in signed_bundles:
        profile = plistlib.loads(run(["security", "cms", "-D", "-i", bundle / "embedded.mobileprovision"]))
        entitlements = plistlib.loads(run(["codesign", "-d", "--entitlements", "-", "--xml", bundle]))
        bundle_info = plistlib.loads((bundle / "Info.plist").read_bytes())
        bundle_id = bundle_info["CFBundleIdentifier"]
        teams = profile["TeamIdentifier"]
        team = entitlements.get("com.apple.developer.team-identifier")
        if team not in teams or (expected_team and team != expected_team):
            raise RuntimeError(f"Signing team mismatch: {bundle_id}")
        signed_id = entitlements.get("application-identifier", "")
        allowed_id = profile["Entitlements"]["application-identifier"]
        if not signed_id.endswith("." + bundle_id) or not fnmatch.fnmatchcase(signed_id, allowed_id):
            raise RuntimeError(f"Provisioning profile does not cover: {bundle_id}")
        with tempfile.TemporaryDirectory(prefix="ipa-cert-") as temporary:
            prefix = Path(temporary) / "signer"
            run(["codesign", "-d", "--extract-certificates=" + str(prefix), bundle])
            certificate = Path(str(prefix) + "0")
            certificate_sha1 = hashlib.sha1(certificate.read_bytes()).hexdigest().upper()
            allowed_certificates = {hashlib.sha1(cert).hexdigest().upper() for cert in profile["DeveloperCertificates"]}
            if certificate_sha1 not in allowed_certificates:
                raise RuntimeError(f"Signing certificate is absent from profile: {bundle_id}")
            enddate = run(["openssl", "x509", "-inform", "DER", "-in", certificate,
                           "-noout", "-enddate"]).decode().strip().split("=", 1)[1]
            certificate_expiry = datetime.strptime(enddate, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=UTC)
        profile_expiry = profile["ExpirationDate"].replace(tzinfo=UTC)
        devices = profile.get("ProvisionedDevices")
        enterprise = bool(profile.get("ProvisionsAllDevices"))
        if devices is None and not enterprise:
            raise RuntimeError("App Store profiles cannot be installed by this IPA workflow")
        if devices is not None:
            all_devices = set(devices) if all_devices is None else all_devices.intersection(devices)
        profiles.append({
            "bundle_id": bundle_id, "team_id": team, "profile_name": profile["Name"],
            "profile_uuid": profile["UUID"], "profile_expires_at": timestamp(profile_expiry),
            "certificate_sha1": certificate_sha1, "certificate_expires_at": timestamp(certificate_expiry),
            "valid_until": timestamp(min(profile_expiry, certificate_expiry)),
            "signing_kind": "development" if entitlements.get("get-task-allow") else ("enterprise" if enterprise else "ad-hoc"),
            "requires_developer_mode": bool(entitlements.get("get-task-allow")),
        })
    valid_until = min(datetime.fromisoformat(p["valid_until"]) for p in profiles)
    renew_at = valid_until - timedelta(days=renew_days)
    now = datetime.now(UTC)
    return {
        "bundle_id": info["CFBundleIdentifier"], "display_name": info.get("CFBundleDisplayName", info["CFBundleName"]),
        "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
        "minimum_os": info["MinimumOSVersion"], "device_families": info.get("UIDeviceFamily", []),
        "architectures": architectures, "profiles": profiles,
        "registered_devices": sorted(all_devices) if all_devices is not None else None,
        "valid_until": timestamp(valid_until), "renew_at": timestamp(renew_at),
        "remaining_days": max(0, (valid_until - now).days),
        "expired": now >= valid_until, "renewal_due": now >= renew_at,
        "requires_developer_mode": any(p["requires_developer_mode"] for p in profiles),
        "signature_verified": True,
    }


def extract_ipa(ipa, destination):
    # Validate paths before invoking ditto; it otherwise follows archive symlinks.
    with zipfile.ZipFile(ipa) as archive:
        for entry in archive.infolist():
            relative = PurePosixPath(entry.filename)
            if relative.is_absolute() or ".." in relative.parts or "\\" in entry.filename:
                raise RuntimeError("Unsafe path in IPA")
            if stat.S_ISLNK(entry.external_attr >> 16):
                raise RuntimeError("IPA contains symlinks; this iOS workflow expects flat device bundles")
        damaged = archive.testzip()
        if damaged:
            raise RuntimeError(f"Damaged IPA member: {damaged}")
    run(["ditto", "-x", "-k", ipa, destination])
    apps = list((destination / "Payload").glob("*.app"))
    if len(apps) != 1:
        raise RuntimeError("Expected exactly one top-level app in IPA Payload")
    return apps[0]


def verify_resources(root, app, checks):
    result = []
    for check in checks:
        source, packed = root / check["source"], app / check["bundle"]
        files = lambda folder: {p.relative_to(folder) for p in folder.rglob("*") if p.is_file() and p.name != ".DS_Store"}
        source_files = files(source)
        if not source_files or source_files != files(packed):
            raise RuntimeError(f"Bundled resource inventory differs: {check['source']}")
        for relative in sorted(source_files):
            if digest(source / relative) != digest(packed / relative):
                raise RuntimeError(f"Bundled resource checksum differs: {relative}")
        result.append({"source": check["source"], "bundle": check["bundle"], "verified_files": len(source_files)})
    return result


def build(args):
    config_path = args.config.resolve()
    config = json.loads(config_path.read_text())
    root = (config_path.parent / config.get("root", "..")).resolve()
    container = (root / config["project"]).resolve()
    kind = "-workspace" if container.suffix == ".xcworkspace" else "-project"
    if not container.exists() or container.suffix not in (".xcodeproj", ".xcworkspace"):
        raise RuntimeError("Configure an existing .xcodeproj or .xcworkspace")
    method = args.method or config.get("method", "debugging")
    if method not in ("debugging", "release-testing"):
        raise RuntimeError("Choose debugging (development) or release-testing (Ad Hoc)")
    if not config.get("team_id"):
        raise RuntimeError("Set your own team_id in ignored Config/IPA.local.json before packaging for physical devices")
    name = config["name"]
    if not re.fullmatch(r"[A-Za-z0-9_-]+", name):
        raise RuntimeError("Config name must be a filename-safe identifier")
    work = root / "build/IPA"
    work.mkdir(parents=True, exist_ok=True)
    refresh = args.refresh_signing or args.renew
    provisioning = ["-allowProvisioningUpdates"] if refresh else []
    original_cwd = Path.cwd()
    os.chdir(root)
    try:
        for command in config.get("prepare", []):
            print(f"Preparing: {command[0]} {command[1]}", flush=True)
            output = run(command)
            print(output.decode(errors="replace").strip(), flush=True)
        with tempfile.TemporaryDirectory(prefix="package-", dir=work) as temporary:
            scratch = Path(temporary)
            archive = scratch / "Release.xcarchive"
            print(f"Building optimized Release; log: {work / 'archive.log'}", flush=True)
            run(["xcodebuild", kind, container, "-scheme", config["scheme"],
                 "-configuration", "Release", "-destination", "generic/platform=iOS",
                 "-derivedDataPath", scratch / "DerivedData", "-archivePath", archive,
                 *provisioning, "DEVELOPMENT_TEAM=" + config["team_id"], "CODE_SIGN_STYLE=Automatic",
                 "CODE_SIGN_IDENTITY=Apple Development", "archive"], work / "archive.log")
            archived_apps = list((archive / "Products/Applications").glob("*.app"))
            if len(archived_apps) != 1:
                raise RuntimeError("Archive must contain one main application")
            inspect_app(archived_apps[0], config["team_id"], config["bundle_id"])
            options = {"method": method, "destination": "export", "teamID": config["team_id"],
                       "thinning": "<none>", "stripSwiftSymbols": True,
                       "manageAppVersionAndBuildNumber": False, "signingStyle": "automatic"}
            options_path = scratch / "ExportOptions.plist"
            options_path.write_bytes(plistlib.dumps(options))
            print(f"Exporting local IPA ({method}); log: {work / 'export.log'}", flush=True)
            run(["xcodebuild", "-exportArchive", "-archivePath", archive,
                 "-exportPath", scratch / "Export", "-exportOptionsPlist", options_path,
                 *provisioning], work / "export.log")
            ipas = list((scratch / "Export").glob("*.ipa"))
            if len(ipas) != 1:
                raise RuntimeError("Expected one exported IPA")
            app = extract_ipa(ipas[0], scratch / "VerifiedIPA")
            report = inspect_app(app, config["team_id"], config["bundle_id"], config.get("renew_before_days", 30))
            if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", report["version"]):
                raise RuntimeError("App version must contain only numeric version components")
            expected_kind = "development" if method == "debugging" else "ad-hoc"
            if any(p["signing_kind"] != expected_kind for p in report["profiles"]):
                raise RuntimeError("Exported signature does not match selected distribution method")
            if report["expired"]:
                raise RuntimeError("Exported IPA already expired; refresh the signing credentials")
            report["resources"] = verify_resources(root, app, config.get("resource_checks", []))
            if config.get("branding_verifier"):
                print(run(["swift", root / config["branding_verifier"], root, app]).decode().strip(), flush=True)
                report["branding"] = json.loads((root / "Branding/release-branding.lock.json").read_text())
            output = (args.output or root / "Releases" / report["version"]).resolve()
            stem = f"{name}-{report['version']}-iOS-Release-{expected_kind}"
            manifest = output / (stem + ".json")
            previous_paths = {manifest} | set((root / "Releases").glob(f"*/{name}-*-iOS-Release-{expected_kind}.json"))
            if args.output:
                previous_paths |= set(output.glob(f"{name}-*-iOS-Release-{expected_kind}.json"))
            if args.renew:
                previous_expiries = []
                for previous_path in previous_paths:
                    if previous_path.is_file():
                        previous = json.loads(previous_path.read_text())
                        if previous.get("bundle_id") == report["bundle_id"]:
                            previous_expiries.append(datetime.fromisoformat(previous["valid_until"]))
                if previous_expiries and datetime.fromisoformat(report["valid_until"]) <= max(previous_expiries):
                    raise RuntimeError("Renewal did not extend the signing expiry. Current IPA was preserved. "
                                       "Renew/download the certificate and profile in Xcode or the Apple Developer account, then retry.")
            output.mkdir(parents=True, exist_ok=True)
            ipa = output / (stem + ".ipa")
            report.update(configuration="Release", export_method=method, created_at=timestamp(datetime.now(UTC)),
                          ipa=ipa.name, size_bytes=ipas[0].stat().st_size, sha256=digest(ipas[0]),
                          temporary_builds_removed=True)
            # Validate first, then replace the canonical IPA for this version/signing method.
            staged = output / (stem + ".ipa.partial")
            shutil.copy2(ipas[0], staged)
            staged.replace(ipa)
            manifest.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
            (output / (stem + ".ipa.sha256")).write_text(f"{report['sha256']}  {ipa.name}\n")
            shutil.copy2(options_path, output / (stem + ".ExportOptions.plist"))
            for log in ("archive.log", "export.log"):
                shutil.copy2(work / log, output / (stem + "." + log))
        print(f"IPA ready: {ipa}\nSignature valid until: {report['valid_until']}\nRenew before: {report['renew_at']}\nTemporary archive/app/build copies removed.", flush=True)
    finally:
        os.chdir(original_cwd)


def inspect_or_install(args):
    ipa = args.ipa.resolve()
    with tempfile.TemporaryDirectory(prefix="ipa-install-") as temporary:
        app = extract_ipa(ipa, Path(temporary))
        report = inspect_app(app)
        report.update(ipa=ipa.name, sha256=digest(ipa))
        if args.command == "inspect":
            print(json.dumps(report, ensure_ascii=False, indent=2))
            return
        if report["expired"]:
            raise RuntimeError("IPA signature has expired; renew it before installing")
        details = json.loads(run(["xcrun", "devicectl", "device", "info", "details",
                                 "--device", args.device, "--json-output", "-"]))["result"]
        hardware = details["hardwareProperties"]
        if hardware.get("reality") != "physical":
            raise RuntimeError("Use a physical iPhone or iPad")
        udid = hardware["udid"]
        if report["registered_devices"] is not None and udid not in report["registered_devices"]:
            raise RuntimeError("Device is not registered in this IPA's provisioning profiles")
        software = details["deviceProperties"]
        version = lambda value: tuple(int(part) for part in value.split(".")) + (0,) * (3 - len(value.split(".")))
        if version(software["osVersionNumber"]) < version(report["minimum_os"]):
            raise RuntimeError("Device OS is below the app's minimum OS version")
        if report["requires_developer_mode"] and software.get("developerModeStatus") != "enabled":
            raise RuntimeError("Enable Developer Mode in the device's settings first")
        if not set(hardware.get("supportedDeviceFamilies", [])).intersection(report["device_families"]):
            raise RuntimeError("The app does not support this device family")
        installed = json.loads(run(["xcrun", "devicectl", "device", "info", "apps", "--device", args.device,
                                    "--bundle-id", report["bundle_id"], "--json-output", "-"]))["result"]["apps"]
        candidate_version = (version(report["version"]), version(report["build"]))
        if any((version(a.get("version", "0")), version(a.get("bundleVersion", "0"))) > candidate_version
               for a in installed if a.get("bundleIdentifier") == report["bundle_id"]):
            raise RuntimeError("Refusing to replace a newer installed version/build with an older IPA")
        if DEFAULT_CONFIG.is_file():
            config = json.loads(DEFAULT_CONFIG.read_text())
            if config.get("bundle_id") == report["bundle_id"] and config.get("branding_verifier"):
                root = (DEFAULT_CONFIG.parent / config.get("root", "..")).resolve()
                print(run(["swift", root / config["branding_verifier"], root, app]).decode().strip(), flush=True)
        print(f"Installing {report['display_name']} {report['version']} to {software['name']} (in-place update).", flush=True)
        result = json.loads(run(["xcrun", "devicectl", "device", "install", "app", "--device", args.device,
                                app, "--json-output", "-"]))
        verification = json.loads(run(["xcrun", "devicectl", "device", "info", "apps", "--device", args.device,
                                      "--bundle-id", report["bundle_id"], "--json-output", "-"]))
        apps = verification["result"]["apps"]
        if not any(a.get("bundleIdentifier") == report["bundle_id"] and a.get("version") == report["version"]
                   and a.get("bundleVersion") == report["build"] for a in apps):
            raise RuntimeError("Installation returned but the installed version could not be verified")
        receipt = {"installed_at": timestamp(datetime.now(UTC)), "device_name": software["name"],
                   "device_udid": udid, "bundle_id": report["bundle_id"], "version": report["version"],
                   "build": report["build"], "ipa_sha256": report["sha256"],
                   "install_result": result["result"], "installed_apps": apps}
        if args.receipt:
            args.receipt.parent.mkdir(parents=True, exist_ok=True)
            args.receipt.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
        print(f"Installed and verified. Signature valid until: {report['valid_until']}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    package = commands.add_parser("build", help="Build optimized Release and export a locally installable IPA")
    package.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    package.add_argument("--output", type=Path)
    package.add_argument("--method", choices=("debugging", "release-testing"))
    package.add_argument("--refresh-signing", action="store_true", help="Allow Xcode to update signing using its signed-in account")
    package.add_argument("--renew", action="store_true", help="Refresh signing and require a later expiry before replacing an existing IPA")
    inspect = commands.add_parser("inspect", help="Verify IPA signature and show actual profile/certificate expiry")
    inspect.add_argument("ipa", type=Path)
    install = commands.add_parser("install", help="Verify IPA and update a paired physical device without uninstalling")
    install.add_argument("ipa", type=Path)
    install.add_argument("--device", required=True, help="Paired device name or UDID")
    install.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    try:
        build(args) if args.command == "build" else inspect_or_install(args)
    except (RuntimeError, OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
