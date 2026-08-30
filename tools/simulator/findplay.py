#!/usr/bin/env python3
"""Locate the session button's play glyph in a simctl screenshot."""
import sys
import numpy as np
from PIL import Image

def find_one(path, tpl_path='tpl_play.png'):
    img = np.asarray(Image.open(path).convert('L'), dtype=np.float32)
    tpl0 = Image.open(tpl_path)
    best = None
    for s in (1.0, 1.5):
        tpl = np.asarray(tpl0.resize((int(tpl0.width*s), int(tpl0.height*s))), dtype=np.float32)
        th, tw = tpl.shape
        if th >= img.shape[0] or tw >= img.shape[1]: continue
        t = tpl - tpl.mean()
        tn = np.sqrt((t*t).sum())
        # brute force over a stride, then refine
        for stride, region in ((4, None), (1, 'refine')):
            if region is None:
                ys = range(0, img.shape[0]-th, stride)
                xs = range(0, img.shape[1]-tw, stride)
            else:
                by, bx = best[1], best[2]
                ys = range(max(0,by-5), min(img.shape[0]-th, by+6))
                xs = range(max(0,bx-5), min(img.shape[1]-tw, bx+6))
            for y in ys:
                for x in xs:
                    w = img[y:y+th, x:x+tw]
                    wc = w - w.mean()
                    denom = np.sqrt((wc*wc).sum()) * tn
                    if denom == 0: continue
                    score = (wc*t).sum()/denom
                    if best is None or score > best[0]:
                        best = (score, y, x, th, tw, s)
    score, y, x, th, tw, s = best
    return score, (x + tw/2, y + th/2), s

def find(path):
    best = None
    for tpl in ('tpl_play.png', 'tpl_record.png', 'tpl_play_popped.png'):
        r = find_one(path, tpl)
        if best is None or r[0] > best[0]: best = r
    return best

if __name__ == '__main__':
    print(find(sys.argv[1]))
