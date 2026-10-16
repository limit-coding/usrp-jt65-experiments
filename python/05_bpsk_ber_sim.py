#!/usr/bin/env python3
"""Offline BPSK BER baseline; use it before doing the same waveform over USRP."""
import argparse, numpy as np
def main():
    p=argparse.ArgumentParser(); p.add_argument('--snr-db',type=float,default=6); p.add_argument('--bits',type=int,default=200000); p.add_argument('--seed',type=int,default=1); a=p.parse_args(); rng=np.random.default_rng(a.seed); b=rng.integers(0,2,a.bits); s=2*b-1; sigma=10**(-a.snr_db/20); r=s+rng.normal(0,sigma,a.bits); bh=(r>=0).astype(int); print(f'SNR={a.snr_db:.1f} dB, bits={a.bits}, errors={np.count_nonzero(b!=bh)}, BER={np.mean(b!=bh):.6g}')
if __name__=='__main__': main()
