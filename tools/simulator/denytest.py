#!/usr/bin/env python3
"""Refused-microphone regression: every tap on the session button must put an
alert up, and none of them may open a session."""
import subprocess, sys, time
import numpy as np
from PIL import Image
import simctl_ui, findplay

BID='Niall.OpenBat'
import os
APP=os.environ.get('OPENBAT_APP','DD/Build/Products/Debug-iphonesimulator/OpenBat.app')
def sh(*a): return subprocess.run(a, capture_output=True, text=True)
def shot(n):
    p=f'{n}.png'; sh('xcrun','simctl','io','booted','screenshot','--type=png',p); return p

def alert_up(path):
    """The alert dims the whole screen and puts a bright title mid-screen."""
    im = Image.open(path).convert('L')
    w,h = im.size
    band = np.asarray(im.crop((int(w*0.30), int(h*0.40), int(w*0.70), int(h*0.62))))
    return band.max() > 200

def run(name, udid, taps=5):
    print(f'\n=== {name}')
    sh('xcrun','simctl','shutdown','all'); sh('xcrun','simctl','boot',udid)
    subprocess.run(['open','-a','Simulator']); time.sleep(20)
    sh('xcrun','simctl','uninstall','booted',BID)
    sh('xcrun','simctl','install','booted',APP)
    sh('xcrun','simctl','privacy','booted','revoke','microphone',BID)
    sh('xcrun','simctl','privacy','booted','grant','location',BID)
    sh('xcrun','simctl','launch','booted',BID,'-onboarding.hasCompletedWelcome','YES',
       '-locator.structuralOnly','YES','-release.lastSeenBuild','130',
       '-release.reonboardedBuild','130','-tour.hasNudged','YES')
    time.sleep(12)
    p0 = shot(f'{name}_d0')
    sc,(bx,by),_ = findplay.find(p0)
    if sc < 0.55: print(f'  !! glyph not found ({sc:.2f})'); return
    simctl_ui.calibrate()
    ok = True
    for i in range(1, taps+1):
        simctl_ui.tap(bx, by, recalibrate=(i==1)); time.sleep(3)
        p = shot(f'{name}_d{i}')
        up = alert_up(p)
        print(f'  tap {i}: alert {"shown" if up else "MISSING"}')
        ok &= up
        if up:   # dismiss with Cancel — bottom-left of the two buttons
            im = Image.open(p); w,h = im.size
            simctl_ui.tap(w*0.41, h*0.552); time.sleep(2)
    # nothing may have been left running
    last = shot(f'{name}_dz')
    still = findplay.find(last)[0]
    print(f'  session button still idle afterwards: {still:.2f} '
          f'({"yes" if still > 0.55 else "NO - something started"})')
    print('  RESULT:', 'PASS' if ok and still > 0.55 else 'FAIL')

for a in sys.argv[1:]:
    n,u = a.split('='); run(n,u)
