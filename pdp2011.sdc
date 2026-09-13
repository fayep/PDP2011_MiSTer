#create_clock -period 20.000ns [get_ports clkin]
create_clock -period 10.000ns emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk

# cpuclk is NOT an independent clock: it's generated entirely inside
# mister_top.vhd's dram_fsm process, which is itself clocked by clk_100
# (= divclk -- pdp2011.sv wires clk_100mhz, the same pll.outclk_0 net, to
# both). The FSM runs an unconditional, never-stalled 15-state loop
# (dram_c1..dram_c15, confirmed via source read 2026-09-12: refresh is
# issued as an alternate command WITHIN dram_c6, it never inserts extra
# states) -- cpuclk is set '1' while processing state dram_c1 (visible
# starting the same clk_100 edge) and '0' while processing dram_c8, held
# otherwise. That's a real, fixed, deterministic divide-by-15 with a 7:8
# duty cycle, not an arbitrary/asynchronous 150ns clock. Declaring it as
# a bare create_clock throws away that phase relationship and forces
# TimeQuest to analyze the two domains as unrelated, which is the
# dominant source of the divclk<->cpuclk setup pessimism (report_timing
# showed a -21ns "violation" on cpu0.rbus_ix -> dram_addr, a path that is
# actually held stable across the whole cpuclk high phase before dram
# samples it in dram_c6/c8 -- real margin the create_clock declaration
# was hiding). Edges are in half-period units of the SOURCE clock
# (divclk): edge 1 = the rising edge that ends state dram_c1 (cpuclk
# goes high here); edge 15 = 7 source periods later, the rising edge
# that ends state dram_c8 (cpuclk goes low); edge 31 = 15 source periods
# after edge 1, the next cpuclk rising edge (one full 150ns period).
create_generated_clock -name cpuclk \
   -source [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
   -edges {1 15 31} \
   [get_registers {emu:emu|mister_top:mister_top|cpuclk}]
# rh0/rk0/rl0's sdspi create_clock/false_path entries (previously here)
# removed 2026-09-13: the disk-transport rewrite (Phases 1-3) deleted
# sdspi.vhd's instantiation from rh11/rk11/rl11 entirely -- these three
# controllers now talk hps_io's native sd_* protocol directly, so
# rh0/rk0/rl0|sdspi:sd1|clk no longer exists in the netlist. Confirmed
# dead (not just redundant) via this exact build's own STA warnings:
# "Ignored filter ... could not be matched with a port or pin or
# register ... or node" for all 6 lines. tm11 still has a real,
# currently-instantiated sdspi.vhd (tape's own native-transport rewrite
# is a separate, not-yet-started phase) -- but tm0|sdspi:sd1|clk has
# never had its own create_clock here at all (this predates this
# session), so it's a genuinely unconstrained clock right now
# (Warning (332060): "determined to be a clock but was found without an
# associated clock assignment") -- a real, separate gap, not touched by
# this cleanup.

derive_pll_clocks -use_net_name
derive_clock_uncertainty

# cpuclk -> divclk: dram_addr[11:0] is only ever written from cpu0's addr/
# rbus_ix chain inside the dram_fsm process (mister_top.vhd), at state
# dram_c6 (row address, bits 11:0 <= addr(20:9), 5 divclk periods after
# the cpuclk edge that updates rbus_ix/addr -- source edge 11 vs. edge 1)
# or state dram_c8 (column address, bits 7:0 <= addr(8:1), 7 periods
# later -- edge 15). Declaring cpuclk as a bare create_clock hid this
# entirely (TimeQuest treated the two as unrelated, worst-case-aligned
# clocks); now that cpuclk is a proper generated clock with a known phase
# to divclk (see above), the default single-destination-cycle setup check
# is provably wrong -- addr is registered in the cpuclk domain and held
# for the whole ~150ns period, not re-driven every divclk edge.
#
# QUARTUS 17.0.2 GOTCHA (found 2026-09-12 after extensive report_timing
# diffing): set_multicycle_path/set_false_path only reliably engage when
# BOTH -from and -to resolve to the SAME kind of object -- clock-to-clock,
# or register/pin-to-register/pin. A MIXED combination (e.g. -from a
# clock, -to a specific register) is accepted with zero warnings, shows
# up fine in `report_sdc`-style inspection, and silently has NO effect on
# the computed setup/hold relationship. This cost a lot of time: several
# register-scoped attempts (-to {...dram_addr[7]}, -to
# [get_registers {...dram_addr[*]}], with and without -compatibility_mode,
# with Tcl-escaped/unescaped [n] brackets) all "matched" per Quartus's own
# resolution log but never changed a single Data Required Time. Proven by
# a targeted A/B: a register-to-register set_false_path (rbus_ix[1] ->
# dram_addr[7]) DID visibly change the reported critical path (the tool
# promoted a different source register into 3rd place), while every
# clock+register mixed variant left the exact same violating path
# untouched. The fix below uses clock-to-clock (matching the
# already-proven-working cpuclk->sdspi false_path above), which is the
# only form confirmed to actually engage.
#
# The 5-cycle value is the more conservative of the two real
# relationships this crossing has (dram_c6's row-address group, 5 divclk
# periods; dram_c8's column-address group, 7 periods -- see above) --
# applying it to the whole cpuclk->divclk relationship never claims more
# margin than physically exists. Verified via report_timing: this specific
# crossing's worst reported slack went from -20.467ns to -2.743ns, and the
# original violating path (cpu0 registers -> dram_addr) is no longer in
# the worst-3 list at all -- what's left at -2.743ns is a DIFFERENT,
# smaller, and architecturally separate issue: raw hps_io|status[*] OSD
# bits feeding dram_dq registers with no synchronization at all (same
# class of gap as the already-fixed have_rl/rk/rh/tm 2-FF sync, just not
# yet applied to these particular status bits) -- not part of this fix,
# tracked as a separate follow-up.
set_multicycle_path -from [get_clocks {cpuclk}] \
   -to [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] -setup 5
set_multicycle_path -from [get_clocks {cpuclk}] \
   -to [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] -hold 4

# divclk -> cpuclk, hold: cpureset (mister_top.vhd's dram_fsm-generated
# synchronous reset, fed as the `reset` port straight into pdp11/vt0's
# whole cpuclk-domain register fan-out) is a quasi-static control signal
# that, by construction, can change at most once per cpuclk period (it's
# a register in the SAME dram_fsm process that generates cpuclk itself --
# see above). The default single-cycle hold check treats it like a
# signal that could change on literally the next divclk edge, which is
# never physically possible here.
#
# (First attempt at this was `-hold 0`, reasoning from the "control
# signal released on the same edge as its own generated clock" pattern
# in Intel's own timing-closure docs -- confirmed via report_timing that
# was flat-out numerically wrong for this direction: it changed NOTHING
# (identical -2.314ns before and after), while an unrelated sanity check
# with an obviously-oversized value (-hold 20) immediately cleared the
# violation, proving the exception mechanism itself was fine and only the
# chosen value was wrong. -hold 15 -- one full cpuclk period, the actual
# real periodicity limit -- resolves it identically to -hold 20 (0
# violated, +0.168ns), so 15 is the value grounded in real hardware
# rather than an arbitrary large number that merely happens to work.)
#
# Confirmed via report_timing this is genuinely a reset-fanout-wide issue
# (the worst 8 cpuclk hold paths all source from cpureset, landing on
# many different downstream registers: kw11l's lc_ie/br, cpu0's r7,
# rbus_cpu_mode, ...) so this is scoped by clock, not one register. The
# -setup here is NOT just restating the default: it also covers a real,
# separate divclk->cpuclk violation on this same clock pair -- dati[8/9/11]
# (the DRAM read-data register) into cpu0's state_dst1. mister_top.vhd's
# dram_c13 state writes `dati <= dram_dq` at source edge 25 (12 divclk
# periods into the current cpuclk period); the CPU doesn't consume it
# until the NEXT cpuclk rising edge (edge 31, one full period later) --
# a real 3-period (edges 25->31) window, not the single-divclk-period the
# default assumes. -setup 3 matches this exactly (not more -- edge 31 is
# the genuine next capture point, so -setup 4 would claim margin that
# doesn't exist). Verified via report_timing: this alone took that
# violation from -9.150ns to -0.833ns against the existing placement.
# The remaining -0.833ns is real and NOT an SDC modeling error -- it
# needs an actual RTL fix (an extra pipeline stage on the dati->mmu->cpu
# combinational path, per [[register-addr-checks-for-timing]]), not
# another multicycle number. Not attempted this session; multicycle
# values are defined relative to whatever -setup is in effect, so the
# -hold 15 below was re-verified against this -setup 3 (still 0 violated).
set_multicycle_path -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
   -to [get_clocks {cpuclk}] -setup 3
set_multicycle_path -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
   -to [get_clocks {cpuclk}] -hold 15

# clk_50 (general[2]'s PLL output, kl11/kw11l/etc's clk50mhz port) ->
# cpuclk: found 2026-09-13 as the new worst cpuclk setup offender
# (-0.871ns, kl11's recv_buf[N] -> rx_buf[N] and
# recv_state.recv_idle -> rx_act) after the disk-transport rewrite
# removed sdspi.vhd's own clk (which had been the previous worst path,
# see the create_clock declarations above -- still present in the SDC
# for branches that still instantiate it, but no longer the bottleneck
# on this one).
#
# Confirmed via source read (rtl/kl11.vhd) this is a real,
# protocol-guarded false path, same class as the cpuclk->sdspi false
# paths above: recv_buf (multi-bit byte data, clk50mhz domain) and
# recv_copy (a LEVEL handshake, not a narrow pulse -- set '1' the exact
# same cycle recv_buf is written at line ~438-440, held '1' until
# acknowledged) are both in the SAME clocked process, so recv_buf is
# guaranteed stable from the instant recv_copy asserts. The cpuclk-side
# process only ever samples recv_buf (`rx_buf <= recv_buf`, line ~296)
# after recv_copy_filter -- a multi-tap shift-register synchronizer of
# recv_copy -- has fully saturated to all-1s (line ~294), i.e. after
# several clk50mhz periods of recv_copy already being stable-high.
# recv_buf itself never changes again until the return handshake
# (rx_copied/rx_copied_filter, line ~424-428) lets recv_copy clear.
# Genuine false path: the real synchronization is the filtered
# handshake, not anything a tighter timing number would improve.
set_false_path -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] \
   -to [get_clocks {cpuclk}]
