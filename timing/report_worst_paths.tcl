project_open pdp2011
create_timing_netlist
read_sdc
update_timing_netlist

report_timing -setup -npaths 2 -detail full_path -stdout \
  -to_clock {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk} \
  -from_clock {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}

report_timing -setup -npaths 2 -detail full_path -stdout \
  -to_clock {emu:emu|mister_top:mister_top|cpuclk} \
  -from_clock {emu:emu|mister_top:mister_top|cpuclk}
