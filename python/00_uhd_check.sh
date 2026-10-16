#!/bin/sh
set -eu
SERIAL="${1:-347380A}"
echo "== UHD devices =="
uhd_find_devices
echo "== Detailed probe: $SERIAL =="
uhd_usrp_probe --args "serial=$SERIAL"
