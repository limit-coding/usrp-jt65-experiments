#!/usr/bin/env python3
"""Capture two synchronized B210 RX channels and report amplitude/phase difference."""
import argparse, numpy as np
from gnuradio import blocks, gr, uhd
def main():
    p=argparse.ArgumentParser(); p.add_argument('--serial',default='347380A'); p.add_argument('--freq',type=float,default=100.6e6); p.add_argument('--rate',type=float,default=1e6); p.add_argument('--gain',type=float,default=30); p.add_argument('--seconds',type=float,default=1); a=p.parse_args(); n=int(a.rate*a.seconds)
    tb=gr.top_block('B210 dual RX'); src=uhd.usrp_source(f'serial={a.serial}',uhd.stream_args(cpu_format='fc32',channels=[0,1])); src.set_samp_rate(a.rate); src.set_center_freq(a.freq,0); src.set_center_freq(a.freq,1); src.set_gain(a.gain,0); src.set_gain(a.gain,1); src.set_antenna('RX2',0); src.set_antenna('RX2',1); h0=blocks.head(gr.sizeof_gr_complex,n); h1=blocks.head(gr.sizeof_gr_complex,n); s0=blocks.vector_sink_c(); s1=blocks.vector_sink_c(); tb.connect((src,0), h0, s0); tb.connect((src,1), h1, s1); tb.run(); x=np.asarray(s0.data()); y=np.asarray(s1.data()); z=np.vdot(x,y)/(np.linalg.norm(x)*np.linalg.norm(y)+1e-20); print(f'RMS0={np.sqrt(np.mean(abs(x)**2)):.4g}, RMS1={np.sqrt(np.mean(abs(y)**2)):.4g}, phase(y relative x)={np.angle(z,deg=True):.2f} deg, coherence={abs(z):.4f}')
if __name__=='__main__': main()
