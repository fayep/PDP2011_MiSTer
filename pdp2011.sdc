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

# All disk and tape controllers (rk11, rl11, rh11, tm11) talk to hps_io directly
# through rtl/mister_blkdev.vhd (clk_100 <-> cpuclk handshake): no SPI clocks.

derive_pll_clocks -use_net_name
derive_clock_uncertainty

# --- cpuclk <-> divclk ---------------------------------------------------
# cpuclk is a fabric register, so its edges reach the CPU's flops several
# ns (~6.7 ns in 7a6cd5e) after the divclk edge that made them. Quartus
# counts -setup multicycles in DESTINATION periods and -hold in SOURCE
# periods unless told otherwise, so every exception here says -start/-end
# explicitly. (The old "-setup 3 / -hold 14" into cpuclk meant 3 x 140 ns
# and effectively no hold check; "-hold 4" out of cpuclk was 4 x 140 ns.)
set divclk {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}

# cpuclk -> divclk: the DRAM FSM samples the CPU's address/control at the
# edge ending dram_c6 (row, 5 divclk periods after the cpuclk rise) or
# dram_c8 (column/data, 7). The controllers' block address/handshake
# registers are read by mister_blkdev only after a synchronised start, so
# they have at least as long. Hold is checked at the launch edge.
set_multicycle_path -setup -end 5 -from [get_clocks {cpuclk}] -to [get_clocks $divclk]
set_multicycle_path -hold  -end 4 -from [get_clocks {cpuclk}] -to [get_clocks $divclk]

# divclk -> cpuclk: only the DRAM read data has more than one divclk period.
# dati is loaded at the edge ending dram_c12 (edge 23) and used at the next
# cpuclk rise (edge 29): 3 divclk periods. Hold back at the real launch edge.
# Everything else divclk -> cpuclk is either a synchroniser input (below) or
# must meet the strict single-period default.
set_multicycle_path -setup -start 3 -from [get_registers {emu:emu|mister_top:mister_top|dati[*]}] -to [get_clocks {cpuclk}]
set_multicycle_path -hold  -start 2 -from [get_registers {emu:emu|mister_top:mister_top|dati[*]}] -to [get_clocks {cpuclk}]

# Synchroniser first stages (2-FF, clk_100 <-> cpuclk): the crossing is
# asynchronous by design; the second stage is what the logic uses.
set_false_path -to [get_registers {*mister_blkdev:*|*_m}]
set_false_path -to [get_registers {emu:emu|mister_top:mister_top|cpureset_s1}]
set_false_path -to [get_registers {emu:emu|mister_top:mister_top|tm_img_mounted_meta* emu:emu|mister_top:mister_top|rk_img_mounted_meta* emu:emu|mister_top:mister_top|rl_img_mounted_meta* emu:emu|mister_top:mister_top|rh_img_mounted_meta*}]
# tm11 synchronises the tape-change toggle on both cpuclk edges (mc_e, mc_n)
set_false_path -to [get_registers {*tm11:tm0|mc_e[0] *tm11:tm0|mc_n[0]}]
# PS/2 keyboard lines from hps_io: an asynchronous serial protocol, sampled
# by the VT's ps2 filter shift register (ps2_cfilter) on cpuclk.
set_false_path -from [get_registers {*ps2_device:keyboard|ps2_clk_out *ps2_device:keyboard|ps2_dat_out}] -to [get_clocks {cpuclk}]
# front panel keyboard (pdp2011.sv): the gate on the VT's PS/2 lines changes only while the line is idle,
# and the panel switches are quasi-static and 2-FF synchronised on cpuclk (paneldriver also debounces)
set_false_path -from [get_registers {emu:emu|vt_kbd_off}] -to [get_clocks {cpuclk}]
set_false_path -to [get_registers {emu:emu|mister_top:mister_top|panel_sw_meta[*]}]

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
