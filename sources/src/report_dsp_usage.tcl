# Run after synthesis from the Vivado Tcl console:
#   source src/report_dsp_usage.tcl
#
# Prints every DSP48 primitive with its complete synthesized hierarchy and
# verifies the current 20-engine build: 20 engines x 6 DSP48E1 = 120 DSPs.

set expected_cores 20
set expected_dsp_per_core 6
set expected_total [expr {$expected_cores * $expected_dsp_per_core}]

if {[llength [get_runs -quiet synth_1]] == 0} {
    error "Synthesis run 'synth_1' does not exist."
}

if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    error "Run synth_1 successfully before sourcing this script."
}

open_run synth_1

set dsp_cells [lsort [get_cells -hierarchical -filter {REF_NAME =~ DSP48*}]]
puts ""
puts "DSP48 cells: [llength $dsp_cells]"
foreach dsp $dsp_cells {
    puts "  $dsp"
}
puts ""

set non_mandel_dsp {}
# This script may be sourced repeatedly in one Vivado Tcl session. An empty
# "array set" does not erase existing elements, so explicitly remove the old
# per-core counts before rebuilding them from the current synthesized netlist.
unset -nocomplain core_dsp_count
array set core_dsp_count {}
foreach dsp $dsp_cells {
    # Generated-block separators can vary with hierarchy flattening, but the
    # core instance name u_px is retained in every expected DSP path.
    if {![string match "*u_px*" $dsp]} {
        lappend non_mandel_dsp $dsp
    }

    if {[regexp {G_PX\[([0-9]+)\]\.u_px} $dsp -> core_index]} {
        if {![info exists core_dsp_count($core_index)]} {
            set core_dsp_count($core_index) 0
        }
        incr core_dsp_count($core_index)
    }
}

set bad_core_count 0
for {set core 0} {$core < $expected_cores} {incr core} {
    set count 0
    if {[info exists core_dsp_count($core)]} {
        set count $core_dsp_count($core)
    }
    if {$count != $expected_dsp_per_core} {
        puts "FAIL: Mandel engine $core uses $count DSP48 cells; expected $expected_dsp_per_core."
        incr bad_core_count
    }
}

if {[llength $dsp_cells] == $expected_total &&
    [llength $non_mandel_dsp] == 0 &&
    $bad_core_count == 0} {
    puts "PASS: $expected_total DSP48 cells, $expected_dsp_per_core in each of $expected_cores Mandel engines."
} else {
    if {[llength $dsp_cells] != $expected_total} {
        puts "FAIL: found [llength $dsp_cells] DSP48 cells; expected $expected_total."
    }
    if {[llength $non_mandel_dsp] != 0} {
        puts "FAIL: DSP48 cells outside pixel_gen_mandelbrot:"
        foreach dsp $non_mandel_dsp {
            puts "  $dsp"
        }
    }
}
