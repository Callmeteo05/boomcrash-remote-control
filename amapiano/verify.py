import wave, numpy as np, os, sys
sys.path.insert(0, '/home/user/boomcrash-remote-control/amapiano')
from song import SECTIONS, BAR, BPM, STEP, KICK, LOG_A, LOG_B, LOG_C, TITLE


def rd(p):
    with wave.open(p) as w:
        a = np.frombuffer(w.readframes(w.getnframes()), dtype='<i2').astype(np.float32) / 32768
        return a.reshape(-1, w.getnchannels()), w.getframerate()


m, sr = rd(f'out/{TITLE}.wav')
dur = len(m) / sr
print(f"master: {int(dur//60)}:{dur%60:04.1f}  peak {20*np.log10(np.max(np.abs(m))):.2f} dBFS")
mono = m.mean(1).astype(np.float64)

bands = [(20,60),(60,120),(120,250),(250,500),(500,1000),(1000,2000),(2000,4000),(4000,8000),(8000,16000)]
seg = mono[:1<<23]
S = np.abs(np.fft.rfft(seg * np.hanning(len(seg))))**2
f = np.fft.rfftfreq(len(seg), 1/sr); tot = S.sum()
print("\nspectral balance (% energy):")
for lo, hi in bands:
    p = S[(f>=lo)&(f<hi)].sum()/tot*100
    print(f"  {lo:>5}-{hi:<5} {p:6.2f}%  {'#'*int(p*1.2)}")

print(f"\nL/R correlation: {np.corrcoef(m[:,0], m[:,1])[0,1]:.3f}")

print("\nsection RMS:")
bar = 0
for name, length, prog, mix in SECTIONS:
    s, e = int(bar*BAR*sr), int((bar+length)*BAR*sr)
    r = 20*np.log10(np.sqrt(np.mean(mono[s:e]**2))+1e-12)
    t0 = bar*BAR
    print(f"  {name:<11} bar {bar:>3} @{int(t0//60)}:{t0%60:04.1f}  {r:6.2f} dB  {'#'*int(r+30)}")
    bar += length

# groove check: does any log-drum hit collide with a kick?
print("\ngroove placement (16th steps within a bar):")
print(f"  kick      {sorted(KICK)}")
for nm, pat in (('log A', LOG_A), ('log B', LOG_B), ('log C', LOG_C)):
    steps = sorted(s for s, _, _ in pat)
    clash = sorted(set(steps) & set(KICK))
    print(f"  {nm:<9} {steps}   collides with kick: {clash or 'none'}")
