#!/usr/bin/env python3
"""Plot a Welch-like averaged spectrum from a saved complex IQ .npy file."""
import argparse, pathlib
import numpy as np
import matplotlib.pyplot as plt

def main():
    p=argparse.ArgumentParser(); p.add_argument('--input', required=True); p.add_argument('--rate', type=float, required=True)
    p.add_argument('--center', type=float, default=0); p.add_argument('--out', default=None); p.add_argument('--nfft', type=int, default=4096)
    a=p.parse_args(); x=np.asarray(np.load(a.input), dtype=np.complex64)
    n=min(a.nfft, x.size); x=x[:x.size//n*n].reshape(-1,n); w=np.hanning(n)
    ps=np.mean(np.abs(np.fft.fftshift(np.fft.fft(x*w, axis=1), axes=1))**2, axis=0)/(np.sum(w*w)*a.rate)
    f=np.fft.fftshift(np.fft.fftfreq(n, 1/a.rate))+a.center; db=10*np.log10(ps+1e-20)
    # Exclude the centre bin region. B210 leaves a DC/LO-leakage spur at the tuned
    # frequency, and without this the strongest "peak" is the receiver itself.
    keep=np.abs(f-a.center)>20e3; idx=np.flatnonzero(keep)
    peak=idx[np.argsort(db[keep])[-10:][::-1]]
    for i in peak[:5]: print(f'peak {f[i]/1e6:.6f} MHz, {db[i]:.1f} dB/Hz')
    out=a.out or str(pathlib.Path(a.input).with_suffix('.spectrum.png')); plt.figure(figsize=(10,4)); plt.plot(f/1e6,db); plt.xlabel('Frequency (MHz)'); plt.ylabel('PSD (dB/Hz)'); plt.grid(True); plt.tight_layout(); plt.savefig(out,dpi=150); print('saved',out)

if __name__=='__main__': main()
