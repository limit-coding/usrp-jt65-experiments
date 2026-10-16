#!/bin/sh
set -eu
GNURADIO_PYTHON="${GNURADIO_PYTHON:-/opt/homebrew/Cellar/gnuradio/3.10.12.0_11/libexec/venv/bin/python}"
if [ ! -x "$GNURADIO_PYTHON" ]; then
  GNURADIO_PYTHON="$(command -v python3)"
fi
exec "$GNURADIO_PYTHON" "$@"
