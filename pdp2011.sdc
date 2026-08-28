#create_clock -period 20.000ns [get_ports clkin]
create_clock -period 10.000ns emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk
create_clock -period 140.000ns emu:emu|mister_top:mister_top|cpuclk
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
set_false_path -from [get_clocks {emu:emu|mister_top:mister_top|cpuclk}] \
  -to [get_clocks {emu:emu|mister_top:mister_top|unibus:pdp11|rh11:rh0|sdspi:sd1|clk}]
set_false_path -from [get_clocks {emu:emu|mister_top:mister_top|cpuclk}] \
  -to [get_clocks {emu:emu|mister_top:mister_top|unibus:pdp11|rk11:rk0|sdspi:sd1|clk}]
set_false_path -from [get_clocks {emu:emu|mister_top:mister_top|cpuclk}] \
  -to [get_clocks {emu:emu|mister_top:mister_top|unibus:pdp11|rl11:rl0|sdspi:sd1|clk}]

