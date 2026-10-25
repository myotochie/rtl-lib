# synth_vivado.tcl
# Out-of-context synthesis and implementation of one IP configuration, to get
# area and fmax numbers.
#
# Run from the repository root (Vivado in the PATH):
#   vivado -mode batch -nolog -nojournal -source scripts/synth_vivado.tcl -tclargs sync_fifo 32 1024
#
# Arguments: <ip_name> <WIDTH> <DEPTH>
# Raw reports: build/vivado/<ip>_<WIDTH>x<DEPTH>/
# The block is timed alone, with 0 ns input and output delays, against a 4.0 ns clock.

if {[llength $argv] != 3} {
    puts "usage: vivado -mode batch -source scripts/synth_vivado.tcl -tclargs <ip> <WIDTH> <DEPTH>"
    exit 1
}
lassign $argv ip width depth

set part   xc7z010clg400-1
set period 4.0
set tag    "${ip}_${width}x${depth}"
set out    "build/vivado/$tag"
file mkdir $out

read_vhdl -vhdl2008 "ip/$ip/rtl/${ip}_pkg.vhd"
read_vhdl -vhdl2008 "ip/$ip/rtl/${ip}.vhd"

synth_design -top $ip -part $part -mode out_of_context \
    -generic WIDTH=$width -generic DEPTH=$depth

create_clock -name clk -period $period [get_ports clk_i]
set_input_delay  0 -clock clk [get_ports -filter {DIRECTION == IN && NAME != clk_i}]
set_output_delay 0 -clock clk [all_outputs]

opt_design
place_design
route_design

report_utilization    -file "$out/utilization.rpt"
report_timing_summary -file "$out/timing_summary.rpt"

proc grab {text pattern} {
    if {[regexp $pattern $text -> value]} { return $value }
    return "n/a"
}

set util   [report_utilization -return_string]
set lut    [grab $util {\|\s*(?:Slice|CLB) LUTs\*?\s*\|\s*(\d+)\s*\|}]
set lutram [grab $util {\|\s*LUT as Memory\s*\|\s*(\d+)\s*\|}]
set ff     [grab $util {\|\s*(?:Slice|CLB) Registers\s*\|\s*(\d+)\s*\|}]
set bram   [grab $util {\|\s*Block RAM Tile\s*\|\s*([0-9.]+)\s*\|}]

set wns  [get_property SLACK [get_timing_paths -setup -max_paths 1]]
set fmax [format %.1f [expr {1000.0 / ($period - $wns)}]]

puts ""
puts "RESULT $tag: LUT=$lut LUTRAM=$lutram FF=$ff BRAM=$bram WNS=$wns ns, fmax=$fmax MHz (period $period ns, part $part, Vivado [version -short])"