#!/usr/bin/env python3
"""Transmit one JT65 frame and record it through one B210 in one GNU Radio flowgraph.

The MATLAB R2025b SDRu objects cannot run the existing hwt_tx/hwt_rx scripts
concurrently on one B210. This program handles both UHD streams in one process
and saves 11025 Hz IQ for exp4_jt65_rx_demod.m to decode in MATLAB.

No RF transmission happens without --tx. Use --simulate to test the file path
without a radio. For a cable loopback, insert at least 30 dB attenuation.
"""

import argparse
import pathlib
import subprocess
import sys
import tempfile


RADIO_RATE = 204800
BASEBAND_RATE = 11025
MASTER_CLOCK = 30.72e6


def radio_backend(args):
    from gnuradio import blocks, gr, uhd

    radio_args = f"serial={args.serial}"
    tb = gr.top_block("JT65 one-B210 TX/RX")
    tx = uhd.usrp_sink(
        radio_args, uhd.stream_args(cpu_format="fc32", channels=[0])
    )
    rx = uhd.usrp_source(
        radio_args, uhd.stream_args(cpu_format="fc32", channels=[0])
    )
    for radio in (tx, rx):
        radio.set_clock_rate(MASTER_CLOCK)
        radio.set_samp_rate(RADIO_RATE)
        radio.set_center_freq(args.freq, 0)
    tx.set_gain(args.tx_gain, 0)
    rx.set_gain(args.rx_gain, 0)
    tx.set_antenna("TX/RX", 0)
    rx.set_antenna("RX2", 0)

    print(
        f"TX {tx.get_center_freq(0)/1e6:.6f} MHz via ch1 TX/RX, "
        f"RX {rx.get_center_freq(0)/1e6:.6f} MHz via ch1 RX2, "
        f"rate {rx.get_samp_rate()/1e3:.1f} ksps, "
        f"TX gain {tx.get_gain(0):.1f} dB, RX gain {rx.get_gain(0):.1f} dB",
        flush=True,
    )
    tx_file = blocks.file_source(gr.sizeof_gr_complex, args.tx_file, False)
    rx_head = blocks.head(gr.sizeof_gr_complex, args.samples)
    rx_file = blocks.file_sink(gr.sizeof_gr_complex, args.rx_file)
    tb.connect(tx_file, tx)
    tb.connect(rx, rx_head, rx_file)
    tb.run()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--serial", default="347380A")
    p.add_argument("--freq", type=float, default=435e6, help="RF center in Hz")
    p.add_argument("--tx-gain", type=float, default=0.0)
    p.add_argument("--rx-gain", type=float, default=20.0)
    p.add_argument("--seconds", type=float, default=60.0)
    p.add_argument("--lead-seconds", type=float, default=5.0)
    p.add_argument("--tx", action="store_true", help="explicitly enable RF transmission")
    p.add_argument("--simulate", action="store_true", help="make a synthetic capture without RF")
    p.add_argument("--backend", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--tx-file", help=argparse.SUPPRESS)
    p.add_argument("--rx-file", help=argparse.SUPPRESS)
    p.add_argument("--samples", type=int, help=argparse.SUPPRESS)
    args = p.parse_args()

    if args.backend:
        radio_backend(args)
        return
    if not args.simulate and not args.tx:
        p.error("RF transmission requires --tx; use --simulate for an offline test")

    import numpy as np
    from scipy.io import loadmat, savemat
    from scipy.signal import resample_poly

    project = pathlib.Path(__file__).resolve().parent.parent
    data = project / "data"
    wave_file = data / "jt65_wave.mat"
    if not wave_file.is_file():
        p.error(f"missing {wave_file}; run exp3_jt65_tx_waveform.m with doTransmit=false first")
    mat = loadmat(wave_file)
    wave = np.asarray(mat["wave"]).ravel()
    fs = int(np.asarray(mat["fs"]).item())
    if fs != BASEBAND_RATE or len(wave) != 126 * 4096:
        p.error("jt65_wave.mat does not contain the expected 11025 Hz, 126-slot frame")

    n_rx = round(args.seconds * RADIO_RATE)
    n_lead = round(args.lead_seconds * RADIO_RATE)
    tx_wave = resample_poly(wave, 8192, 441).astype(np.complex64)
    tx_wave *= np.float32(0.3 / max(float(np.max(np.abs(tx_wave))), 1e-12))
    if n_lead + len(tx_wave) + 2 * RADIO_RATE > n_rx:
        p.error("capture is too short to contain the full JT65 frame and a 2 s tail")

    output = data / "jt65_one_b210_rx.mat"
    if args.simulate:
        rng = np.random.default_rng(0)
        low = np.zeros(round(args.seconds * BASEBAND_RATE), dtype=np.complex64)
        low_lead = round(args.lead_seconds * BASEBAND_RATE)
        low[low_lead : low_lead + len(wave)] = (0.1 * wave).astype(np.complex64)
        low += (rng.normal(0, 0.003, low.size) + 1j * rng.normal(0, 0.003, low.size)).astype(np.complex64)
        capture = low
    else:
        print("One B210: TX ch1 TX/RX, RX ch1 RX2. Cable loopback needs >=30 dB attenuation.")
        print("Close MATLAB/GNU Radio sessions that currently own this B210.")
        with tempfile.TemporaryDirectory(prefix="jt65-txrx-", dir=data) as tmp:
            tx_path = pathlib.Path(tmp) / "tx.c64"
            rx_path = pathlib.Path(tmp) / "rx.c64"
            tx_iq = np.zeros(n_rx, dtype=np.complex64)
            tx_iq[n_lead : n_lead + len(tx_wave)] = tx_wave
            tx_iq.tofile(tx_path)
            del tx_iq
            runner = project / "python" / "run_gnuradio.sh"
            cmd = [
                str(runner), str(pathlib.Path(__file__).resolve()),
                "--backend", "--serial", args.serial,
                "--freq", str(args.freq), "--tx-gain", str(args.tx_gain),
                "--rx-gain", str(args.rx_gain), "--tx-file", str(tx_path),
                "--rx-file", str(rx_path), "--samples", str(n_rx),
            ]
            subprocess.run(cmd, check=True)
            raw = np.fromfile(rx_path, dtype=np.complex64)
            if raw.size != n_rx:
                raise RuntimeError(f"received {raw.size} samples; expected {n_rx}")
            capture = resample_poly(raw, 441, 8192).astype(np.complex64)

    savemat(
        output,
        {"rx": capture, "fsRx": BASEBAND_RATE, "rxFreq": args.freq,
         "rxGain": args.rx_gain, "recSeconds": args.seconds,
         "captureMode": "simulation" if args.simulate else "one B210 full duplex"},
        do_compression=True,
    )
    print(f"Saved {capture.size} IQ samples at {BASEBAND_RATE} Hz to {output}")
    print("Next: run exp4_jt65_rx_demod.m in MATLAB (useCapturedFile is already true).")


if __name__ == "__main__":
    main()
