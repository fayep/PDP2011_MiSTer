project_open pdp2011 -revision pdp2011
create_timing_netlist
read_sdc
update_timing_netlist

report_timing -setup -npaths 5 -detail full_path -stdout \
  -from_clock {emu:emu|mister_top:mister_top|cpuclk} \
  -to_clock {emu:emu|mister_top:mister_top|cpuclk} \
  -to [get_registers {*xu_enc424j600_shim_inst*}]

report_timing -setup -npaths 5 -detail full_path -stdout \
  -from_clock {emu:emu|mister_top:mister_top|cpuclk} \
  -to_clock {emu:emu|mister_top:mister_top|cpuclk} \
  -from [get_registers {*xu_enc424j600_shim_inst*}]
