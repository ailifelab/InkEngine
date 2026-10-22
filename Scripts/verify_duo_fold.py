#!/usr/bin/env python3
"""Drive Device Hub's real hinge controls from XCTest DUO_FOLD_STEP markers.

Start before xcodebuild, pointing --log to its stdout/stderr file. Only the host
hinge is driven here; XCTest retains exclusive control of app interactions.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time

AX_SOURCE = r'''
import AppKit
import ApplicationServices
let app = AXUIElementCreateApplication(Int32(CommandLine.arguments[1])!)
let target = CommandLine.arguments[2]
func value(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
    var result: CFTypeRef?
    AXUIElementCopyAttributeValue(e, key as CFString, &result)
    return result
}
func find(_ e: AXUIElement) -> AXUIElement? {
    if ["AXButton", "AXMenuItem", "AXMenuButton"].contains(value(e, kAXRoleAttribute) as? String ?? ""),
       (value(e, kAXDescriptionAttribute) as? String) == target || (value(e, kAXTitleAttribute) as? String) == target { return e }
    for child in value(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let found = find(child) { return found }
    }
    return nil
}
guard let button = find(app) else { fputs("Missing native hinge AXButton: \(target)\n", stderr); exit(2) }
let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
guard result == .success else { fputs("Native hinge AXPress failed: \(result.rawValue)\n", stderr); exit(3) }
print("Pressed native hinge: \(target)")
'''

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--device', required=True, help='Exclusive iPhone Duo simulator UUID')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--timeout', type=float, default=1200)
    parser.add_argument('--steps', type=int, default=13)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
    source, helper = args.output / 'native-hinge.swift', args.output / 'native-hinge'
    source.write_text(AX_SOURCE)
    subprocess.run(['xcrun', 'swiftc', str(source), '-o', str(helper)], env=env, check=True)
    started, offset, pending = time.monotonic(), 0, ''
    seen, records = set(), []
    pattern = re.compile(r'DUO_FOLD_STEP_(\d+)_(OPEN|PARTIAL|CLOSED|TABLETOP)\b')
    while time.monotonic() - started < args.timeout:
        if not args.log.exists():
            time.sleep(.1)
            continue
        if args.log.stat().st_size < offset:
            offset, pending = 0, ''
        with args.log.open(errors='replace') as log:
            log.seek(offset)
            pending += log.read()
            offset = log.tell()
        lines = pending.split('\n')
        pending = lines.pop()
        for line in lines:
            for match in pattern.finditer(line):
                number, pose = int(match[1]), match[2]
                if number in seen:
                    continue
                if number != len(seen) + 1:
                    raise RuntimeError(f'Missing hinge marker before step {number}')
                processes = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True)
                candidates = [int(row.strip().split(None, 1)[0]) for row in processes.splitlines()
                              if row.strip().endswith('/DeviceHub.app/Contents/MacOS/DeviceHub')]
                if len(candidates) != 1:
                    raise RuntimeError(f'Expected one Device Hub process, found {candidates}')
                description = {'OPEN': 'Open', 'PARTIAL': 'Partially Open', 'CLOSED': 'Closed', 'TABLETOP': 'Partially Open'}[pose]
                action = subprocess.run([str(helper), str(candidates[0]), description],
                                        capture_output=True, text=True, timeout=30, check=True)
                print(f'Step {number}: {action.stdout.strip()}', flush=True)
                # The native partial pose preserves the current physical orientation.
                # XCTest requires an actual active horizontal division; it fails
                # rather than pretending a book pose is a tabletop pose.
                # Capture the active panel after the physical hinge transition settles.
                time.sleep(2)
                image = args.output / f'step-{number:02d}-{pose.lower()}.png'
                subprocess.run(['xcrun', 'simctl', 'io', args.device, 'screenshot',
                                '--display=' + ('1' if pose == 'CLOSED' else '3'), str(image)],
                               env=env, check=True, capture_output=True, text=True, timeout=20)
                records.append({'step': number, 'pose': pose, 'nativeAXAction': description,
                                'deviceHubPID': candidates[0], 'screenshot': str(image),
                                'elapsed': round(time.monotonic() - started, 2)})
                (args.output / 'hinge-actions.json').write_text(json.dumps(records, indent=2))
                seen.add(number)
                if len(seen) == args.steps:
                    print(f'Completed {len(seen)} actual hinge actions.', flush=True)
                    return
        if '** TEST FAILED **' in '\n'.join(lines):
            raise RuntimeError(f'XCTest failed after {len(seen)} hinge steps')
        time.sleep(.1)
    raise TimeoutError(f'Only {len(seen)}/{args.steps} hinge markers received within {args.timeout}s')

if __name__ == '__main__':
    main()
