#create_clock -period 20.000ns [get_ports clkin]
create_clock -period 10.000ns emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk

# cpuclk is generated in mister_top.vhd's dram_fsm process on clk_100
# (divclk): set '1' in dram_c1, '0' in dram_c8, and this core's FSM is
# a fixed 14-state loop (dram_c1..dram_c14), so cpuclk is a 140 ns
# divide-by-14 with a 7:7 duty cycle. Edges are in half-periods of
# divclk: 1 = edge ending dram_c1 (rise), 15 = edge ending dram_c8
# (fall), 29 = the next rise. Declared as a generated clock (not a bare
# create_clock) so STA keeps the real phase relationship to divclk.
create_generated_clock -name cpuclk \
   -source [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
   -edges {1 15 29} \
   [get_registers {emu:emu|mister_top:mister_top|cpuclk}]

# rh11/rk11/rl11 still run their own sdspi SPI clocks in this core.
create_clock -period 80.000ns emu:emu|mister_top:mister_top|unibus:pdp11|rh11:rh0|sdspi:sd1|clk
create_clock -period 80.000ns emu:emu|mister_top:mister_top|unibus:pdp11|rk11:rk0|sdspi:sd1|clk
create_clock -period 80.000ns emu:emu|mister_top:mister_top|unibus:pdp11|rl11:rl0|sdspi:sd1|clk

derive_pll_clocks -use_net_name
derive_clock_uncertainty

set_false_path -from [get_clocks {cpuclk}] \
  -to [get_clocks {emu:emu|mister_top:mister_top|unibus:pdp11|rh11:rh0|sdspi:sd1|clk}]
set_false_path -from [get_clocks {cpuclk}] \
  -to [get_clocks {emu:emu|mister_top:mister_top|unibus:pdp11|rk11:rk0|sdspi:sd1|clk}]
set_false_path -from [get_clocks {cpuclk}] \
  -to [get_clocks {emu:emu|mister_top:mister_top|unibus:pdp11|rl11:rl0|sdspi:sd1|clk}]

# sdspi <-> sd_card (sys/sd_card.sv): sd_card runs on clk_100 and treats
# SCK as data -- it samples sck on clk_spi and acts on a detected edge
# (~old_sck & sck), with clk_spi >= 4 x SCK; MOSI/CS are held for half an
# SPI period (40 ns, 4 clk_100 cycles) around that edge, and sdspi samples
# MISO on its own SPI clock likewise. The single-cycle sd1|clk <-> divclk
# checks are not real requirements (they showed -0.05 ns hold): false path.
foreach sdc_c {rh11:rh0 rk11:rk0 rl11:rl0} {
   set_false_path -from [get_clocks "emu:emu|mister_top:mister_top|unibus:pdp11|$sdc_c|sdspi:sd1|clk"] \
      -to [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
   set_false_path -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
      -to [get_clocks "emu:emu|mister_top:mister_top|unibus:pdp11|$sdc_c|sdspi:sd1|clk"]
}

# cpuclk -> divclk: the DRAM FSM samples the CPU's address/data at the
# edge ending dram_c6 (row address, 5 divclk periods after the cpuclk
# rise) or dram_c8 (column/data, 7 periods). -setup 5 is the tighter of
# the two; -hold 4 brings the hold check back to the launch edge.
set_multicycle_path -from [get_clocks {cpuclk}] \
   -to [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] -setup 5
set_multicycle_path -from [get_clocks {cpuclk}] \
   -to [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] -hold 4

# divclk -> cpuclk: dati is loaded at the edge ending dram_c12 (edge 23)
# and consumed at the next cpuclk rise (edge 29): 3 divclk periods.
# cpureset (also from the dram_fsm process) changes at most once per
# cpuclk period: the hold relaxation is one full cpuclk period (14).
set_multicycle_path -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
   -to [get_clocks {cpuclk}] -setup 3
set_multicycle_path -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
   -to [get_clocks {cpuclk}] -hold 14

# kl11 receive data (clk_50 domain) is handed to cpuclk through a level
# handshake with a multi-tap synchroniser: a real false path.
set_false_path -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] \
   -to [get_clocks {cpuclk}]

# hps_io status[] are the OSD settings (model code, serial console,
# reset, ...): they change only on a user action and are followed by a
# reset, so their paths into the core (status[6] -> model-dependent
# memory decode -> dram_addr was the worst, -10.9 ns) are false.
set_false_path -from [get_registers {emu:emu|hps_io:hps_io|status[*]}]

# ---------------------------------------------------------------------------
# SDRAM interface (AS4C32M16SA-7 class, CL3, burst 1). SDRAM_CLK is
# ~clk_100mhz forwarded through a DDIO output (pdp2011.sv), so it is a
# generated clock on the port. Datasheet: tAC(CL3) 5.4 max, tOH 2.5 min,
# tIS 1.5, tIH 0.8 ns; board 0.3..1.0 ns per trace (assumed).
# Read: READA registered at the edge ending dram_c8 (T0), chip data valid
# tAC after its second following edge until tOH after the third; dati is
# captured at the edge ending dram_c12 (T0+40), the second divclk rise
# after the launching SDRAM_CLK edge: -setup -end 2, default hold.
set sdram_divclk {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set sdram_bd_min 0.3
set sdram_bd_max 1.0
create_generated_clock -name SDRAM_CLK -source [get_pins $sdram_divclk] -invert [get_ports {SDRAM_CLK}]

set_input_delay -clock SDRAM_CLK -max [expr {5.4 + 2*$sdram_bd_max}] [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock SDRAM_CLK -min [expr {2.5 + 2*$sdram_bd_min}] [get_ports {SDRAM_DQ[*]}]
set_multicycle_path -setup -end 2 -from [get_clocks {SDRAM_CLK}] -to [get_clocks $sdram_divclk]

set sdram_out [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE}]
set_output_delay -clock SDRAM_CLK -max [expr {1.5 + $sdram_bd_max - $sdram_bd_min}] $sdram_out
set_output_delay -clock SDRAM_CLK -min [expr {-0.8 - ($sdram_bd_max - $sdram_bd_min)}] $sdram_out
set_false_path -to [get_ports {SDRAM_CKE}]
