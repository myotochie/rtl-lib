# synth_vivado_async.tcl
# Out-of-context synthesis and implementation of async_fifo, to get area, the
# frequency at which timing is met in each clock domain, and the checks that make
# the clock crossing safe in hardware (SPEC section 10).
#
# Run from the repository root, in cmd after settings64.bat:
#   vivado -mode batch -nolog -nojournal -source scripts/synth_vivado_async.tcl -tclargs 32 1024 2 6.6
#
# Arguments: <WIDTH> <DEPTH> <SYNC_STAGES> [<PERIOD_NS>, default 4.0]
# Raw reports: build/vivado/async_fifo_<WIDTH>x<DEPTH>_s<SYNC_STAGES>_<PERIOD>ns/
#
# Constraints:
#   - two clocks, wr_clk and rd_clk, of PERIOD_NS each, no relation assumed;
#   - every path between the two clocks (Gray pointers, data memory) gets
#     set_max_delay -datapath_only, one clock period. No false path and no
#     clock groups, because they would hide the crossing paths from the timer;
#   - the memory to rd_data_o paths get SYNC_STAGES periods instead, because a
#     written word is only declared valid SYNC_STAGES + 1 read edges later;
#   - I/O delays are 0 ns, relative to the clock of their own domain.
#
# TIMING=MET when the setup slack is not negative in both domains and on both
# crossings. WHS_reg is the worst hold slack between registers. The hold slack
# on the ports is not reported: in out-of-context mode with 0 ns input delays and
# no clock source it is an artifact of the mode, not of the design.

if {[llength $argv] != 3 && [llength $argv] != 4} {
    puts "usage: vivado -mode batch -source scripts/synth_vivado_async.tcl -tclargs <WIDTH> <DEPTH> <SYNC_STAGES> \[<PERIOD_NS>\]"
    exit 1
}
lassign $argv width depth stages
set period 4.0
if {[llength $argv] == 4} { set period [lindex $argv 3] }

set ip     async_fifo
set part   xc7z010clg400-1
set tag    "${ip}_${width}x${depth}_s${stages}_${period}ns"
set out    "build/vivado/$tag"
file mkdir $out

read_vhdl -vhdl2008 "ip/$ip/rtl/${ip}_pkg.vhd"
read_vhdl -vhdl2008 "ip/$ip/rtl/${ip}.vhd"

synth_design -top $ip -part $part -mode out_of_context \
    -generic WIDTH=$width -generic DEPTH=$depth -generic SYNC_STAGES=$stages

create_clock -name wr_clk -period $period [get_ports wr_clk_i]
create_clock -name rd_clk -period $period [get_ports rd_clk_i]

set_input_delay  0 -clock wr_clk [get_ports -filter {DIRECTION == IN  && NAME =~ wr_* && NAME != wr_clk_i}]
set_input_delay  0 -clock rd_clk [get_ports -filter {DIRECTION == IN  && NAME =~ rd_* && NAME != rd_clk_i}]
set_output_delay 0 -clock wr_clk [get_ports -filter {DIRECTION == OUT && NAME =~ wr_*}]
set_output_delay 0 -clock rd_clk [get_ports -filter {DIRECTION == OUT && NAME =~ rd_*}]

set_max_delay -datapath_only -from [get_clocks wr_clk] -to [get_clocks rd_clk] $period
set_max_delay -datapath_only -from [get_clocks rd_clk] -to [get_clocks wr_clk] $period

# Data memory (write clock) to rd_data_o (read clock). A written word is only declared valid
# SYNC_STAGES + 1 read edges after the write, so this path has at least SYNC_STAGES read
# periods to settle. The only write-clock paths that end on rd_data_o are the memory paths.
# Ending on a port is more specific than ending on a clock, so this constraint replaces the
# one-period default above for these paths only (SPEC section 10).
set_max_delay -datapath_only -from [get_clocks wr_clk] -to [get_ports rd_data_o*] [expr {$stages * $period}]

opt_design
place_design
route_design

report_utilization       -file "$out/utilization.rpt"
report_timing_summary    -file "$out/timing_summary.rpt"
report_clock_interaction -file "$out/clock_interaction.rpt"
report_cdc -details      -file "$out/cdc.rpt"
report_timing -from [get_clocks wr_clk] -to [get_clocks rd_clk] -max_paths 10 -file "$out/crossing_wr_to_rd.rpt"
report_timing -from [get_clocks rd_clk] -to [get_clocks wr_clk] -max_paths 10 -file "$out/crossing_rd_to_wr.rpt"

proc grab {text pattern} {
    if {[regexp $pattern $text -> value]} { return $value }
    return "n/a"
}

# Worst setup slack of the paths from one clock to another, n/a if there is none.
proc slack {from to} {
    set paths [get_timing_paths -setup -max_paths 1 -from [get_clocks $from] -to [get_clocks $to]]
    if {[llength $paths] == 0} { return "n/a" }
    return [get_property SLACK $paths]
}

# Worst hold slack between registers, n/a if there is none.
proc hold_reg {} {
    set paths [get_timing_paths -hold -max_paths 1 -from [all_registers] -to [all_registers]]
    if {[llength $paths] == 0} { return "n/a" }
    return [get_property SLACK $paths]
}

proc fmax {period wns} {
    if {$wns eq "n/a"} { return "n/a" }
    return [format %.1f [expr {1000.0 / ($period - $wns)}]]
}

proc not_negative {v} {
    return [expr {$v ne "n/a" && $v >= 0}]
}

set util   [report_utilization -return_string]
set lut    [grab $util {\|\s*(?:Slice|CLB) LUTs\*?\s*\|\s*(\d+)\s*\|}]
set lutram [grab $util {\|\s*LUT as Memory\s*\|\s*(\d+)\s*\|}]
set ff     [grab $util {\|\s*(?:Slice|CLB) Registers\s*\|\s*(\d+)\s*\|}]
set bram   [grab $util {\|\s*Block RAM Tile\s*\|\s*([0-9.]+)\s*\|}]

set wns_wr [slack wr_clk wr_clk]
set wns_rd [slack rd_clk rd_clk]
set wns_xw [slack wr_clk rd_clk]
set wns_xr [slack rd_clk wr_clk]
set whs    [hold_reg]

set met "VIOLATED"
if {[not_negative $wns_wr] && [not_negative $wns_rd] && [not_negative $wns_xw] && [not_negative $wns_xr]} {
    set met "MET"
}

# The synchronizer flip-flops must carry ASYNC_REG: 2 chains x SYNC_STAGES x (log2(DEPTH)+1) bits.
set async_ffs [llength [get_cells -hierarchical -filter {ASYNC_REG == TRUE}]]
set ptr_bits  [expr {int(round(log($depth) / log(2))) + 1}]
set async_exp [expr {2 * $stages * $ptr_bits}]

puts ""
puts "RESULT $tag: TIMING=$met at [format %.1f [expr {1000.0 / $period}]] MHz (period $period ns) LUT=$lut LUTRAM=$lutram FF=$ff BRAM=$bram WNS_wr=$wns_wr ns, WNS_rd=$wns_rd ns, WNS_wr_to_rd=$wns_xw ns, WNS_rd_to_wr=$wns_xr ns, WHS_reg=$whs ns, fmax_wr=[fmax $period $wns_wr] MHz, fmax_rd=[fmax $period $wns_rd] MHz, ASYNC_REG_FF=$async_ffs (expected $async_exp) (part $part, Vivado [version -short])"