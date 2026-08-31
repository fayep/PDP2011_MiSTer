project_open pdp2011 -revision pdp2011
create_timing_netlist -model slow -temperature 100 -voltage 1100
read_sdc
update_timing_netlist
report_timing -setup -from_clock {emu:emu|mister_top:mister_top|cpuclk} -to_clock {emu:emu|mister_top:mister_top|cpuclk} -npaths 15 -detail full_path -panel_name {cpuclk worst setup paths} -file cpuclk_worst_setup.rpt
