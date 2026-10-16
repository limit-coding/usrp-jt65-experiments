#!/usr/bin/env python3
"""Transmit a low-level complex tone for a cabled loopback test."""
import argparse, signal
import numpy as np
from gnuradio import analog, gr, uhd

class Tone(gr.top_block):
    def __init__(self,a):
        super().__init__('B210 TX tone'); src=analog.sig_source_c(a.rate,analog.GR_COS_WAVE,a.offset,10**(a.amplitude_dbfs/20),0)
        sink=uhd.usrp_sink(f'serial={a.serial}',uhd.stream_args(cpu_format='fc32',channels=[0])); sink.set_samp_rate(a.rate); sink.set_center_freq(a.freq,0); sink.set_gain(a.gain,0); sink.set_antenna('TX/RX',0); self.connect(src,sink)
def main():
    p=argparse.ArgumentParser(); p.add_argument('--serial',default='347380A'); p.add_argument('--freq',type=float,default=433e6); p.add_argument('--rate',type=float,default=1e6); p.add_argument('--offset',type=float,default=100e3); p.add_argument('--gain',type=float,default=0); p.add_argument('--amplitude-dbfs',type=float,default=-30); p.add_argument('--tx',action='store_true'); a=p.parse_args()
    if not a.tx: raise SystemExit('Refusing to transmit: add --tx after connecting a 30 dB+ attenuator or suitable antenna/load.')
    tb=Tone(a); signal.signal(signal.SIGINT,lambda *_:tb.stop()); print('transmitting; Ctrl-C to stop'); tb.start(); tb.wait()
if __name__=='__main__': main()
