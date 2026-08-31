project_open pdp2011
create_timing_netlist -model slow -temperature 100 -voltage 1100
read_sdc
update_timing_netlist

report_timing -setup -npaths 3 -detail full_path -stdout \
  -to_clock {emu:emu|mister_top:mister_top|unibus:pdp11|rh11:rh0|sdspi:sd1|clk}
