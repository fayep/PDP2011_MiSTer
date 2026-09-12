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
create_clock -period 80.000ns emu:emu|mister_top:mister_top|unibus:pdp11|rh11:rh0|sdspi:sd1|clk
create_clock -period 80.000ns emu:emu|mister_top:mister_top|unibus:pdp11|rk11:rk0|sdspi:sd1|clk
create_clock -period 80.000ns emu:emu|mister_top:mister_top|unibus:pdp11|rl11:rl0|sdspi:sd1|clk

derive_pll_clocks -use_net_name
derive_clock_uncertainty

# cpuclk -> sdspi crossings (rh0/rk0/rl0): the only signals crossing this
# boundary are quasi-static per-command config registers (e.g. rh11's
# rmdc, "desired cylinder number", a UNIBUS register written once by the
# guest driver before a disk command and held stable for the whole
# operation) consumed only deep inside sdspi.vhd's own multi-state command
# sequencer, itself gated behind a real filtered/debounced start handshake
# (read_start_filter/write_start_filter). Confirmed via source reading
# (2026-08-27), not assumed -- see rtl/sdspi.vhd:161-182 and the
# sdcard_addr consumption at rtl/sdspi.vhd:442-458. Genuine false path, not
# a hazard a synchronizer would improve on -- the handshake already
# provides the real synchronization at the protocol level.
set_false_path -from [get_clocks {cpuclk}] \
  -to [get_clocks {emu:emu|mister_top:mister_top|unibus:pdp11|rh11:rh0|sdspi:sd1|clk}]
set_false_path -from [get_clocks {cpuclk}] \
  -to [get_clocks {emu:emu|mister_top:mister_top|unibus:pdp11|rk11:rk0|sdspi:sd1|clk}]
set_false_path -from [get_clocks {cpuclk}] \
  -to [get_clocks {emu:emu|mister_top:mister_top|unibus:pdp11|rl11:rl0|sdspi:sd1|clk}]

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
