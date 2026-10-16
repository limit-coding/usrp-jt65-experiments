#!/usr/bin/env python3
"""Receive a wideband FM station and write 48 kHz mono WAV."""
import argparse, math, pathlib
from gnuradio import analog, blocks, fft, filter, gr, uhd
from gnuradio.filter import firdes

def main():
    p=argparse.ArgumentParser(); p.add_argument('--serial',default='347380A'); p.add_argument('--freq',type=float,default=100.6e6); p.add_argument('--gain',type=float,default=30); p.add_argument('--seconds',type=int,default=10); p.add_argument('--tau',type=float,default=50.0,help='de-emphasis time constant in us (50 CN/EU, 75 US)'); p.add_argument('--out',default='data/fm.wav'); a=p.parse_args()
    rf=1_000_000; quad=250_000; audio=50_000; out_rate=48_000; decim=5
    pathlib.Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    tb=gr.top_block('B210 WFM receive'); src=uhd.usrp_source(f'serial={a.serial}',uhd.stream_args(cpu_format='fc32',channels=[0])); src.set_samp_rate(rf); src.set_center_freq(a.freq,0); src.set_gain(a.gain,0); src.set_antenna('RX2',0)
    ch=filter.freq_xlating_fir_filter_ccc(4,firdes.low_pass(1,rf,100e3,25e3),0,rf)
    # analog.wfm_rcv would be shorter, but it hardcodes fm_deemph's default tau
    # (75 us, the US standard) and exposes no way to override it. China uses
    # 50 us, so the same chain is spelled out here with tau set explicitly.
    max_dev=75e3
    demod=analog.quadrature_demod_cf(quad/(2*math.pi*max_dev))
    trans=quad/32
    audio_lpf=filter.fir_filter_fff(decim,firdes.low_pass(1.0,quad,quad/2/decim-trans,trans,fft.window.WIN_HAMMING))
    deemph=analog.fm_deemph(audio,a.tau*1e-6)
    rs=filter.rational_resampler_fff(interpolation=24,decimation=25)
    head=blocks.head(gr.sizeof_float,a.seconds*out_rate); sink=blocks.wavfile_sink(a.out,1,out_rate,blocks.FORMAT_WAV,blocks.FORMAT_PCM_16,False)
    tb.connect(src,ch,demod,audio_lpf,deemph,rs,blocks.multiply_const_ff(0.5),head,sink); print('writing',a.out); tb.run()

if __name__=='__main__': main()
