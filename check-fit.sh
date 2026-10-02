#!/bin/sh
# Post-build checks on the fitter report. Exit 0 ok, 1 a check failed,
# 2 report missing/unreadable.
#
# 1. No Quartus register retiming inside the core (emu). Physical-synthesis
#    retiming only preserves a register's clocked behaviour, not its reset
#    or power-up value: retimed reset-initialised registers came out of
#    reset wrong on some placements (r7 = 144020 instead of 165020, the
#    core never booted on that bitstream). The core carries dont_retime
#    (unibus.vhd entity, mister_top.vhd signals, tracecap_dbg.sv); this
#    catches anything new. Retiming in sys/ (ascal, osd, vga_out) is fine.
#
# 2. The SDRAM pad registers are packed into the I/O cells (address and
#    command outputs, DQ input, output and output enable). Unpacked, the
#    100 MHz SDRAM interface runs from fabric registers whose placement
#    changes per build, with no I/O constraints for STA to check: reads
#    sample the wrong word on some seeds. An entity-wide dont_retime on
#    mister_top did exactly that (USER_DONT_TOUCH blocks packing).
#
# usage: check-fit.sh [fit.rpt]   (default output_files/pdp2011.fit.rpt)
RPT=${1:-"$(dirname "$0")/output_files/pdp2011.fit.rpt"}
if [ ! -r "$RPT" ]; then
   echo "check-fit: no fit report at $RPT" >&2
   exit 2
fi
if ! LC_ALL=C grep -a -q 'Physical Synthesis' "$RPT"; then
   echo "check-fit: $RPT has no physical synthesis section" >&2
   exit 2
fi
RC=0

# --- 1. retiming
HITS=$(LC_ALL=C grep -a 'Retimed Register' "$RPT" \
   | awk -F';' '{gsub(/^ +| +$/, "", $2); print $2}' \
   | grep '^emu:emu|')
TOTAL=$(LC_ALL=C grep -a -c 'Retimed Register' "$RPT")
if [ -z "$HITS" ]; then
   echo "check-fit: OK, 0 retimed registers in emu ($TOTAL in sys/)"
else
   N=$(printf '%s\n' "$HITS" | wc -l | tr -d ' ')
   echo "check-fit: FAIL, $N retimed registers in emu:" >&2
   # one line per original register: drop _OTERMn/_RTMn suffixes and bit index
   printf '%s\n' "$HITS" | sed -E 's/(_OTERM|_RTM)[0-9].*//; s/~.*//; s/\[[0-9]+\]$//' \
      | sort | uniq -c | sort -rn >&2
   echo "Add 'attribute dont_retime of <signal> : signal is true' (VHDL) or" >&2
   echo "(* dont_retime *) (Verilog). Not entity-wide on mister_top: see 2." >&2
   RC=1
fi

# --- 2. SDRAM I/O registers. Reads the Output Pins and Bidir Pins tables
# by column name. SDRAM_CLK (inverted clock), SDRAM_CKE and SDRAM_BA[1]
# (constants) have no register to pack.
BAD=$(LC_ALL=C awk -F';' '
   /^; (Output|Bidir|Input) Pins +;/ { split($2, t, " "); table = t[1]; hdr = 0; next }
   /^; Name +; Pin #/ && table != "" {
      for (i = 1; i <= NF; i++) { c = $i; gsub(/^ +| +$/, "", c); col[c] = i }
      hdr = 1; next
   }
   /^\+/ { if (hdr && seen) { table = ""; hdr = 0; seen = 0 } ; next }
   hdr && $2 ~ /^ SDRAM_/ {
      seen = 1
      n = $2; gsub(/ /, "", n)
      if (n == "SDRAM_CLK" || n == "SDRAM_CKE" || n == "SDRAM_BA[1]") next
      o = $(col["Output Register"]); gsub(/ /, "", o)
      if (table == "Output" && o != "yes") print n " output"
      if (table == "Bidir") {
         r = $(col["Input Register"]); gsub(/ /, "", r)
         e = $(col["Output Enable Register"]); gsub(/ /, "", e)
         if (r != "yes") print n " input"
         if (o != "yes") print n " output"
         if (e != "yes") print n " output-enable"
      }
   }' "$RPT")
PINS=$(LC_ALL=C grep -a -c '^; SDRAM_' "$RPT")
if [ "$PINS" -eq 0 ]; then
   echo "check-fit: FAIL, no SDRAM pins found in $RPT" >&2
   RC=1
elif [ -z "$BAD" ]; then
   echo "check-fit: OK, SDRAM address/command/DQ registers packed in the I/O cells"
else
   N=$(printf '%s\n' "$BAD" | wc -l | tr -d ' ')
   echo "check-fit: FAIL, $N SDRAM pad registers not in the I/O cells:" >&2
   printf '%s\n' "$BAD" | head -20 >&2
   LC_ALL=C grep -a -m3 'Cannot modify or duplicate node.*SDRAM\|Cannot modify or duplicate node.*dram' "$RPT" >&2
   RC=1
fi
exit $RC
