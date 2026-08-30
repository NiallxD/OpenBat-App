#!/usr/bin/env python3
import subprocess, sys, time, os
from PIL import Image
import simctl_ui, findplay

import os
APP=os.environ.get('OPENBAT_APP','DD/Build/Products/Debug-iphonesimulator/OpenBat.app')
BID='Niall.OpenBat'
def sh(*a): return subprocess.run(a, capture_output=True, text=True)
def shot(n):
    p=f'{n}.png'; sh('xcrun','simctl','io','booted','screenshot','--type=png',p); return p

def run(name, udid, rotate=False):
    print(f'\n=== {name}')
    sh('xcrun','simctl','shutdown','all'); sh('xcrun','simctl','boot',udid)
    subprocess.run(['open','-a','Simulator']); time.sleep(20)
    sh('xcrun','simctl','uninstall','booted',BID)
    if sh('xcrun','simctl','install','booted',APP).returncode: print('  install failed'); return
    sh('xcrun','simctl','privacy','booted','grant','microphone',BID)
    sh('xcrun','simctl','privacy','booted','grant','location',BID)
    sh('xcrun','simctl','launch','booted',BID,'-onboarding.hasCompletedWelcome','YES',
       '-locator.structuralOnly','YES','-release.lastSeenBuild','130',
       '-release.reonboardedBuild','130','-tour.hasNudged','YES')
    time.sleep(12)
    if rotate:
        subprocess.run(['osascript','-e','tell application "System Events" to tell process "Simulator" to click menu item "Rotate Left" of menu 1 of menu bar item "Device" of menu bar 1'])
        time.sleep(5)
    p0=shot(f'{name}_0')
    sc,(x,y),_=findplay.find(p0)
    print(f'  glyph score {sc:.2f} at {x:.0f},{y:.0f}')
    if sc<0.55: print('  !! glyph not found'); return
    simctl_ui.tap(x,y,recalibrate=True); time.sleep(3); p1=shot(f'{name}_1')
    simctl_ui.tap(x,y); time.sleep(3); p2=shot(f'{name}_2')
    ims=[Image.open(p) for p in (p0,p1,p2)]
    w=520; sc2=w/ims[0].width
    ims=[i.resize((w,int(i.height*sc2))) for i in ims]
    m=Image.new('RGB',(w*3, ims[0].height))
    for i,im in enumerate(ims): m.paste(im,(i*w,0))
    m.save(f'{name}_montage.png'); print(f'  -> {name}_montage.png')

for a in sys.argv[1:]:
    parts=a.split('='); run(parts[0], parts[1], rotate=(len(parts)>2))
