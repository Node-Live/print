#!/bin/bash
# Print queues that stand in for the design's two printers on a CI runner: a 4 x 6 in thermal on USB and a
# Letter/A4 office printer on the network, set as the system default. Neither device exists, so nothing prints.
set -euo pipefail
cd "$(dirname "$0")"
sudo lpadmin -p Rollo_X1038 -D "Rollo X1038" -v "usb://Rollo/X1038?serial=0001" -P label-4x6.ppd -E
sudo lpadmin -p Brother_HL_L2350DW -D "Brother HL-L2350DW" -v "ipp://192.0.2.10/ipp/print" -m drv:///sample.drv/generic.ppd -E
sudo lpadmin -d Brother_HL_L2350DW
lpoptions -d Brother_HL_L2350DW > /dev/null
lpstat -p -d -v
