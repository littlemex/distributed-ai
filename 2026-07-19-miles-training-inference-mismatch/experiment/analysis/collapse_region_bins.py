"""Same binning, but with min_len HELD CONSTANT across bins.

The unconstrained run showed median response length moving 8048 -> 3961 -> 4000 -> 6118 as the
policy collapsed. Since min_len is derived from the median, each bin was measured over a
different prefix length, and alpha is a function of the prefix range -- so the rise in
alpha_within could be a length artefact rather than a change in structure. Fixing min_len to a
value every bin reaches removes that confounder.
"""
import glob, os, re, subprocess, sys
sys.path.insert(0, '/tmp/miles-run')
import numpy as np
from analyze_position_profile import load, token_slope, cumsum_variance_scaling

D = '/fsx/dumps/pt_e5m2_collapse_train'
files = sorted(glob.glob(os.path.join(D, '*.npz')))
BINS = [(2,89),(90,178),(179,267),(268,356)]
LABEL = ['0.026-0.046 (quiet)','0.046-0.40 (onset)','0.40-3.7 (collapsing)','3.7-31.8 (collapsed)']

staged = []
for i,(lo,hi) in enumerate(BINS):
    sub=[f for f in files if lo <= int(re.search(r'_call(\d+)\.npz$',f).group(1)) < hi]
    tmp=f'/tmp/cb{i}'; subprocess.run(['rm','-rf',tmp],check=False); os.makedirs(tmp,exist_ok=True)
    for f in sub: os.symlink(f, os.path.join(tmp, os.path.basename(f)))
    seqs,_,_,_,nnf = load(tmp)
    staged.append((seqs,nnf))

# a length every bin actually reaches, so no bin is measured on a shorter prefix than another
reach = []
for seqs,_ in staged:
    reach.append(sorted(s['response_len'] for s in seqs))
FIXED = 2048
for L in (2048, 1024):
    ok = all(sum(1 for x in r if x >= L) >= 30 for r in reach)
    if ok: FIXED = L; break
print(f"fixed min_len = {FIXED}")
print(f"{'mis_kl band':<24} {'n>=min_len':>10} {'slope|r|':>12} {'alpha_raw':>10} {'alpha_within':>13}")
for i,(seqs,nnf) in enumerate(staged):
    kept=[s for s in seqs if s['response_len']>=FIXED]
    if len(kept)<8:
        print(f"{LABEL[i]:<24} {len(kept):>10} (too few)"); continue
    slope,_=token_slope(kept,FIXED)
    _,a_raw,a_in=cumsum_variance_scaling(seqs,FIXED)
    print(f"{LABEL[i]:<24} {len(kept):>10} {slope:>12.3e} {a_raw:>10.2f} {a_in:>13.2f}"
          + (f"  nonfinite={nnf}" if nnf else ""))
