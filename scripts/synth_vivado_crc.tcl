# synth_vivado_crc.tcl
# Out-of-context synthesis and implementation of crc, to get area and fmax (SPEC section 8).
#
# Run from the repository root, in cmd after settings64.bat:
#   vivado -mode batch -nolog -nojournal -source scripts/synth_vivado_crc.tcl -tclargs CRC-32/ISO-HDLC 32 4.0
#
# Arguments: <ALGORITHM> <DATA_WIDTH> [<PERIOD_NS>]
#   ALGORITHM is CRC-32/ISO-HDLC, CRC-16/IBM-3740, CRC-8/SMBUS or CRC-64/XZ (table below).
#   PERIOD_NS is the clock period of the timing check, 4.0 by default.
# Raw reports: build/vivado/<tag>/
#
# Constraints: one clock clk_i, I/O delays 0 ns.

if {[llength $argv] < 2} {
    puts "usage: vivado -mode batch -source scripts/synth_vivado_crc.tcl -tclargs <ALGORITHM> <DATA_WIDTH> \[<PERIOD_NS>\]"
    exit 1
}
lassign $argv algo dw period
if {$period eq ""} { set period 4.0 }

# name {CRC_WIDTH POLY INIT XOROUT REFIN REFOUT}
set table {
    CRC-32/ISO-HDLC  {32 04C11DB7 FFFFFFFF FFFFFFFF true true}
    CRC-16/IBM-3740  {16 1021 FFFF 0000 false false}
    CRC-8/SMBUS      {8 07 00 00 false false}
    CRC-8/INIT01-TEST {8 07 01 00 false false}
    CRC-64/XZ        {64 42F0E1EBA9EA3693 FFFFFFFFFFFFFFFF FFFFFFFFFFFFFFFF true true}
}
if {![dict exists $table $algo]} {
    puts "unknown ALGORITHM $algo"
    exit 1
}
lassign [dict get $table $algo] w poly init xorout refin refout

set part xc7z010clg400-1
set tag  "crc_[string map {/ _} $algo]_dw${dw}_${period}ns"
set out  "build/vivado/$tag"
file mkdir $out

read_vhdl -vhdl2008 ip/crc/rtl/crc_pkg.vhd
read_vhdl -vhdl2008 ip/crc/rtl/crc.vhd

synth_design -top crc -part $part -mode out_of_context \
    -generic CRC_WIDTH=$w -generic DATA_WIDTH=$dw \
    -generic "POLY=\"$poly\"" -generic "INIT=\"$init\"" -generic "XOROUT=\"$xorout\"" \
    -generic REFIN=$refin -generic REFOUT=$refout

create_clock -name clk -period $period [get_ports clk_i]
set_input_delay  0 -clock clk [get_ports -filter {DIRECTION == IN  && NAME != clk_i}]
set_output_delay 0 -clock clk [get_ports -filter {DIRECTION == OUT}]

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

# Hold slack between registers only (port hold slack is an out-of-context artifact).
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

# Diagnostic: reset polarity of the CRC register. INIT bits at 1 give FDSE, bits at 0 give FDRE.
set fdre_names {}
foreach c [get_cells -hierarchical -quiet -filter {REF_NAME == FDRE}] {
    lappend fdre_names [get_property NAME $c]
}
set n_fdre [llength $fdre_names]
set n_fdse [llength [get_cells -hierarchical -quiet -filter {REF_NAME == FDSE}]]
puts "DIAG $tag: FDRE=$n_fdre FDSE=$n_fdse FDRE_CELLS=$fdre_names"

puts ""
puts "RESULT $tag: LUT=$lut FF=$ff BRAM=$bram DSP=$dsp TIMING=$flag at $fmax MHz (WNS $wns ns at $period ns), WHS_reg=$whs ns (part $part, Vivado [version -short])"