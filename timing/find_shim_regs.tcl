project_open pdp2011 -revision pdp2011
create_timing_netlist
read_sdc
update_timing_netlist

set regs [get_registers -nowarn {*xu_enc424j600*}]
foreach_in_collection r $regs {
   puts [get_node_info -name $r]
}
puts "count: [get_collection_size $regs]"
