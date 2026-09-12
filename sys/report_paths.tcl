project_open pdp2011 -revision pdp2011
create_timing_netlist
read_sdc
update_timing_netlist

report_timing -setup -npaths 8 -detail full_path \
    -to_clock {cpuclk} \
    -file /build/output_files/critical_cpuclk_setup.txt

report_timing -hold -npaths 8 -detail full_path \
    -to_clock {cpuclk} \
    -file /build/output_files/critical_cpuclk_hold.txt

delete_timing_netlist
project_close
