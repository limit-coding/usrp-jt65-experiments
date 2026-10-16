#!/usr/bin/env python3
"""Capture complex IQ from a USRP B210 using GNU Radio."""
import argparse, json, pathlib
import numpy as np
from gnuradio import blocks, gr, uhd

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--serial', default='347380A'); p.add_argument('--freq', type=float, default=100.6e6)
    p.add_argument('--rate', type=float, default=1e6); p.add_argument('--gain', type=float, default=30)
    p.add_argument('--seconds', type=float, default=5); p.add_argument('--channel', type=int, default=0)
    p.add_argument('--antenna', default='RX2'); p.add_argument('--out', default='data/iq.npy')
    a = p.parse_args(); n = max(1, int(a.rate*a.seconds)); frame = min(20000, n)
    out = pathlib.Path(a.out); out.parent.mkdir(parents=True, exist_ok=True)
    tb = gr.top_block('B210 IQ capture')
    src = uhd.usrp_source(f'serial={a.serial}', uhd.stream_args(cpu_format='fc32', channels=[a.channel]))
    src.set_samp_rate(a.rate); src.set_center_freq(a.freq, a.channel); src.set_gain(a.gain, a.channel)
    src.set_antenna(a.antenna, a.channel)
    head = blocks.head(gr.sizeof_gr_complex, n); sink = blocks.vector_sink_c()
    tb.connect(src, head, sink); tb.run()
    iq = np.asarray(sink.data(), dtype=np.complex64); np.save(out, iq)
    meta = dict(serial=a.serial, center_freq=a.freq, sample_rate=a.rate, gain=a.gain,
                antenna=a.antenna, channel=a.channel, samples=int(iq.size))
    out.with_suffix('.json').write_text(json.dumps(meta, indent=2), encoding='utf-8')
    print(f'captured {iq.size} samples -> {out}')

if __name__ == '__main__': main()
