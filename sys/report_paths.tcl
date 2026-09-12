project_open pdp2011 -revision pdp2011
create_timing_netlist
read_sdc
update_timing_netlist

report_timing -setup -npaths 3 -detail full_path \
    -to_clock {cpuclk} \
    -file /build/output_files/critical_cpuclk.txt

report_timing -setup -npaths 3 -detail full_path \
    -to_clock {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk} \
    -file /build/output_files/critical_divclk.txt

delete_timing_netlist
project_close
