#!/usr/bin/env python3
"""Drive a booted simulator by clicking its window on the Mac screen.

Auto-calibrates the device-pixel -> screen-point transform by matching a
simctl screenshot against a screen capture of the Simulator window, so it
works on any device size / window scale without hand-measured constants.
"""
import subprocess, re, os, sys
from PIL import Image
import numpy as np

SCRATCH = os.path.dirname(os.path.abspath(__file__))

def window_frame():
    out = subprocess.check_output(['osascript','-e',
      'tell application "System Events" to tell process "Simulator" to get {position, size} of window 1']).decode()
    n = [int(x) for x in re.findall(r'-?\d+', out)]
    return n[0], n[1], n[2], n[3]

def device_shot(path):
    subprocess.run(['xcrun','simctl','io','booted','screenshot','--type=png',path],
                   check=True, capture_output=True)
    return Image.open(path).convert('L')

def calibrate():
    """Return (scale, ox, oy): screen_pt = (ox, oy) + device_px * scale."""
    ox, oy, ow, oh = window_frame()
    dev = device_shot(os.path.join(SCRATCH, '_cal_dev.png'))
    cap_path = os.path.join(SCRATCH, '_cal_win.png')
    subprocess.run(['screencapture','-x',f'-R{ox},{oy},{ow},{oh}', cap_path], check=True)
    win = Image.open(cap_path).convert('L')
    # screencapture is 2x (retina); work in a small common space.
    W = 220
    best = None
    for s in np.arange(0.30, 1.02, 0.01):          # device px -> window px
        dw, dh = int(dev.width*s), int(dev.height*s)
        if dw > win.width or dh > win.height or dw < 50: continue
        d = np.asarray(dev.resize((max(1,dw//4), max(1,dh//4))), dtype=np.float32)
        w = np.asarray(win.resize((win.width//4, win.height//4)), dtype=np.float32)
        dh4, dw4 = d.shape
        if dh4 > w.shape[0] or dw4 > w.shape[1]: continue
        for yy in range(0, w.shape[0]-dh4+1, 2):
            for xx in range(0, w.shape[1]-dw4+1, 2):
                diff = np.abs(w[yy:yy+dh4, xx:xx+dw4] - d).mean()
                if best is None or diff < best[0]:
                    best = (diff, s, xx*4, yy*4)
    _, s, wx, wy = best
    # window px are 2x screen points, measured from the window origin
    return s/2.0, ox + wx/2.0, oy + wy/2.0

_CAL = None
def tap(px, py, recalibrate=False):
    global _CAL
    if _CAL is None or recalibrate:
        _CAL = calibrate()
    s, ox, oy = _CAL
    sx, sy = ox + px*s, oy + py*s
    subprocess.run(['cliclick', f'c:{sx:.0f},{sy:.0f}'], check=True)
    return sx, sy

if __name__ == '__main__':
    print(calibrate())
