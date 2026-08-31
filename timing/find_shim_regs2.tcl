project_open pdp2011 -revision pdp2011
create_timing_netlist
read_sdc
update_timing_netlist

foreach pat {"*eudast*" "*shim*" "*ddr_mailbox*" "*xu_cs*" "*xu_mosi*" "*cur_opcode*"} {
   set regs [get_registers -nowarn $pat]
   puts "pattern $pat : count [get_collection_size $regs]"
   foreach_in_collection r $regs {
      puts "  [get_node_info -name $r]"
   }
}

set nodes [get_nodes -nowarn {*eudast*}]
puts "all nodes matching *eudast* : count [get_collection_size $nodes]"
foreach_in_collection n $nodes {
   puts "  NODE: [get_node_info -name $n]"
}
