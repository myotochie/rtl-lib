# synth_vivado_uart.tcl
# Out-of-context synthesis and implementation of uart, uart_tx or uart_rx, to get area and
# fmax and to check the synchronizer attributes (SPEC sections 8 and 10).
#
# Run from the repository root, in cmd after settings64.bat:
#   vivado -mode batch -nolog -nojournal -source scripts/synth_vivado_uart.tcl -tclargs uart 100000000 115200 8 0 1
#
# Arguments: <TOP> <CLK_FREQ_HZ> <BAUD> <DATA_BITS> <PARITY> <STOP_BITS> [<PERIOD_NS>]
#   TOP is uart, uart_tx or uart_rx. PERIOD_NS is the clock period of the timing check, 4.0 by default.
# Raw reports: build/vivado/<TOP>_<CLK>_<BAUD>_<D><P><S>_<period>ns/
#
# Constraints: one clock clk_i, I/O delays 0 ns, false path from rxd_i (asynchronous input,
# SPEC section 10).

if {[llength $argv] < 6} {
    puts "usage: vivado -mode batch -source scripts/synth_vivado_uart.tcl -tclargs <TOP> <CLK_FREQ_HZ> <BAUD> <DATA_BITS> <PARITY> <STOP_BITS> \[<PERIOD_NS>\]"
    exit 1
}
lassign $argv top clk baud dbits parity stops period
if {$period eq ""} { set period 4.0 }
if {$top ni {uart uart_tx uart_rx}} {
    puts "TOP must be uart, uart_tx or uart_rx"
    exit 1
}

set part xc7z010clg400-1
set tag  "${top}_${clk}_${baud}_${dbits}${parity}${stops}_${period}ns"
set out  "build/vivado/$tag"
file mkdir $out

read_vhdl -vhdl2008 ip/uart/rtl/uart_pkg.vhd
read_vhdl -vhdl2008 ip/uart/rtl/uart_tx.vhd
read_vhdl -vhdl2008 ip/uart/rtl/uart_rx.vhd
read_vhdl -vhdl2008 ip/uart/rtl/uart.vhd

synth_design -top $top -part $part -mode out_of_context \
    -generic CLK_FREQ_HZ=$clk -generic BAUD=$baud -generic DATA_BITS=$dbits \
    -generic PARITY=$parity -generic STOP_BITS=$stops

create_clock -name clk -period $period [get_ports clk_i]
set_input_delay  0 -clock clk [get_ports -filter {DIRECTION == IN  && NAME != clk_i && NAME != rxd_i}]
set_output_delay 0 -clock clk [get_ports -filter {DIRECTION == OUT}]
if {[llength [get_ports -quiet rxd_i]] > 0} {
    set_false_path -from [get_ports rxd_i]
}

opt_design
place_design
route_design

report_utilization    -file "$out/utilization.rpt"
report_timing_summary -file "$out/timing_summary.rpt"

proc grab {text pattern} {
    if {[regexp $pattern $text -> value]} { return $value }
    return "n/a"
}

proc setup_slack {} {
    set paths [get_timing_paths -setup -max_paths 1]
    if {[llength $paths] == 0} { return "n/a" }
    return [get_property SLACK $paths]
}

# Hold slack between registers only. The hold slack of the ports is an artifact of the
# out-of-context flow (I/O delays of 0 ns).
proc hold_reg {} {
    set paths [get_timing_paths -hold -max_paths 1 -from [all_registers] -to [all_registers]]
    if {[llength $paths] == 0} { return "n/a" }
    return [get_property SLACK $paths]
}

set util [report_utilization -return_string]
set lut  [grab $util {\|\s*(?:Slice|CLB) LUTs\*?\s*\|\s*(\d+)\s*\|}]
set ff   [grab $util {\|\s*(?:Slice|CLB) Registers\s*\|\s*(\d+)\s*\|}]
set bram [grab $util {\|\s*Block RAM Tile\s*\|\s*([0-9.]+)\s*\|}]
set dsp  [grab $util {\|\s*DSPs\s*\|\s*(\d+)\s*\|}]

set wns [setup_slack]
set whs [hold_reg]
if {$wns eq "n/a"} {
    set fmax "n/a"
    set flag "NO_PATH"
} else {
    set fmax [format %.1f [expr {1000.0 / ($period - $wns)}]]
    set flag [expr {$wns >= 0 ? "MET" : "VIOLATED"}]
}

# The two flip-flops of the receiver synchronizer carry ASYNC_REG.
set async_ffs [llength [get_cells -hierarchical -quiet -filter {ASYNC_REG == TRUE}]]
set async_exp [expr {$top eq "uart_tx" ? 0 : 2}]

puts ""
puts "RESULT $tag: LUT=$lut FF=$ff BRAM=$bram DSP=$dsp TIMING=$flag at $fmax MHz (WNS $wns ns at $period ns), WHS_reg=$whs ns, ASYNC_REG_FF=$async_ffs (expected $async_exp) (part $part, Vivado [version -short])"