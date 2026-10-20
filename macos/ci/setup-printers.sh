#!/bin/bash
# Print queues for a CI runner: the design's two printers (a 4 x 6 in thermal on USB, a Letter/A4 office printer on
# the network as the system default) plus a ZPL printer whose socket is a local port the smoke test listens on.
# None of the devices exist, so nothing prints.
set -euo pipefail
cd "$(dirname "$0")"
sudo lpadmin -p Rollo_X1038 -D "Rollo X1038" -v "usb://Rollo/X1038?serial=0001" -P label-4x6.ppd -E
sudo lpadmin -p Brother_HL_L2350DW -D "Brother HL-L2350DW" -v "ipp://192.0.2.10/ipp/print" -m drv:///sample.drv/generic.ppd -E
sudo lpadmin -p Zebra_GX420d -D "Zebra GX420d" -v "socket://127.0.0.1:9100" -P zebra-zpl.ppd -E
sudo lpadmin -d Brother_HL_L2350DW
lpoptions -d Brother_HL_L2350DW > /dev/null
lpstat -p -d -v
