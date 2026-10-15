#!/usr/bin/env python3
"""Exercise production NearbyService over loopback in two isolated simulators.
No Bonjour, OS permission acceptance, keychain pairing, or real-device changes.
"""
import argparse, json, os, pathlib, subprocess, time, uuid
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--app',default='build/NetworkSimulator/Build/Products/Debug-iphonesimulator/Ink Engine.app')
p.add_argument('--sender',default='A1F79A67-441A-4540-A35A-16EE64D749CF')
p.add_argument('--receiver',default='DC21EDE7-7B37-40C5-BC77-D8DFDB319690')
p.add_argument('--port',type=int,default=49321)
p.add_argument('--scenario',choices=['handoff','batch'],default='handoff')
a=p.parse_args()
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
run=str(uuid.uuid4()).upper()
output=pathlib.Path('TestResults')/('nearby-simulators-'+run)
output.mkdir(parents=True)
bundle='org.ailifelab.InkEngine'
def sim(*args,check=True,extra=None):
 return subprocess.run(['xcrun','simctl',*args],env=env| (extra or {}),text=True,capture_output=True,check=check)
reports={}
for role,device in [('sender',a.sender),('receiver',a.receiver)]:
 sim('boot',device,check=False)
 sim('bootstatus',device,'-b')
 sim('terminate',device,bundle,check=False)
 sim('install',device,str(pathlib.Path(a.app).resolve()))
 container=pathlib.Path(sim('get_app_container',device,bundle,'data').stdout.strip())
 reports[role]=container/'Library/Application Support/InkEngineUITests/NetworkTests'/run/'result.json'
 extra={'SIMCTL_CHILD_INK_NEARBY_RUN':run,'SIMCTL_CHILD_INK_NEARBY_ROLE':role,'SIMCTL_CHILD_INK_NEARBY_PORT':str(a.port),'SIMCTL_CHILD_INK_NEARBY_SCENARIO':a.scenario}
 result=sim('launch',device,bundle,'--ui-testing','--nearby-integration',extra=extra)
 (output/(role+'-launch.txt')).write_text(result.stdout+result.stderr)
 print(role,result.stdout.strip(),flush=True)
 if role=='sender':
  end=time.monotonic()+25
  while time.monotonic()<end:
   try:
    value=json.loads(reports[role].read_text())
    if value['state']=='failed': raise RuntimeError(value)
    if value['state']=='listening': break
   except (FileNotFoundError,json.JSONDecodeError): pass
   time.sleep(.25)
  else: raise RuntimeError('sender listener did not become ready')
last={}; values={}; deadline=time.monotonic()+120
while time.monotonic()<deadline:
 for role,path in reports.items():
  try: value=json.loads(path.read_text())
  except (FileNotFoundError,json.JSONDecodeError): continue
  values[role]=value
  state=(value['state'],len(value['checks']),value['detail'])
  if last.get(role)!=state:
   print(role,state,flush=True); last[role]=state
  (output/(role+'.json')).write_text(json.dumps(value,ensure_ascii=False,indent=2))
 if any(v['state']=='failed' for v in values.values()): break
 if len(values)==2 and all(v['state']=='passed' for v in values.values()): break
 time.sleep(.25)
passed=len(values)==2 and all(v['state']=='passed' for v in values.values())
matching=passed and values['sender']['pairingCodes']==values['receiver']['pairingCodes']
revision=passed and values['sender']['originalRevision']==values['receiver']['originalRevision']
summary={'passed':bool(passed and matching and revision),'matchingPairingCodes':bool(matching),'originalRevisionPreserved':bool(revision),'runID':run,'senderSimulator':a.sender,'receiverSimulator':a.receiver,
 'scenario':a.scenario, 'scope':'Real Network.framework loopback TCP and production encrypted transfer/save/reader paths; temporary confirmation injected. Bonjour, OS permissions, LAN reachability, Handoff OS dispatch and physical background behavior not verified.'}
(output/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
print(json.dumps(summary,ensure_ascii=False),flush=True)
print('Evidence:',output,flush=True)
raise SystemExit(0 if summary['passed'] else 1)
