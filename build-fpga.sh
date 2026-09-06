#!/bin/sh
# Quartus compile of pdp2011 in the raetro/quartus:mister container.
#
# -c 12 : give the container 12 of the host's 16 cores.
# -c 12 with -m 16g is fine.
# quartus_map keeps --parallel=1 ON PURPOSE: Quartus 17.0.2's map
#   parallelisation is so inefficient it runs ~25% CPU unpinned vs 100%
#   pinned to one core -- pinned is faster wall-clock. fit/asm/sta are
#   left free to burst (NUM_PARALLEL_PROCESSORS ALL in the qsf).
#
# NOTE: shares the pdp2011-quartus-work volume -- do NOT run two of
# these at once, they will corrupt each other's /work.
set -e
cd "$(dirname "$0")"
exec container run --rm -m 16g -c 12 --arch amd64 \
  -v "pdp2011-quartus-work:/work" \
  -v "$(pwd):/build" \
  raetro/quartus:mister bash -c '
    set -e
    rsync -a --checksum --stats --filter=":- .gitignore" /build/ /work/
    ln -sf pdp2011.sv /work/PDP2011.sv
    ln -sf pdp2011.sdc /work/PDP2011.sdc
    cd /work
    quartus_sh -t sys/build_id.tcl compile pdp2011 pdp2011
    quartus_map --read_settings_files=on --write_settings_files=off pdp2011 -c pdp2011 --parallel=1
    quartus_fit --read_settings_files=on --write_settings_files=off pdp2011 -c pdp2011
    quartus_asm --read_settings_files=on --write_settings_files=off pdp2011 -c pdp2011
    quartus_sta pdp2011 -c pdp2011
    mkdir -p /build/output_files
    cp -a /work/output_files/. /build/output_files/ 2>/dev/null || true
  '
