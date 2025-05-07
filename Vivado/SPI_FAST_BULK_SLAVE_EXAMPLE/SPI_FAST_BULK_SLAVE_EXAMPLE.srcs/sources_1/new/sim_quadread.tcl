########################################################################
# spi_master_abs.tcl – Read two packets with 0x6B , 1 MHz, MODE-0
########################################################################
# Adjust this if your DUT is not /tb/uut
set PATH "/top"

# To run:
# source "D:/Github/voyant-40mhz-spi/Vivado/SPI_FAST_BULK_SLAVE_EXAMPLE/SPI_FAST_BULK_SLAVE_EXAMPLE.srcs/sources_1/new/sim_quadread.tcl"

# ---------------------------------------------------------------------
# Helper that returns a fully-qualified signal path inside PATH
proc sig {name} { return [format "%s/%s" $::PATH $name] }

# Pulse the SPI clock (half-period up, half down)
proc spi_tick {hp} {
    add_force [sig qspi_clk] 1 -radix bin
    run  $hp
    add_force [sig qspi_clk] 0 -radix bin
    run  $hp
}

########################################################################
# Initial conditions ─ everything scheduled at 0 ns
########################################################################
add_force [sig qspi_clk]  {0 0ns} -radix bin   ;# idle low
add_force [sig qspi_cs]   {1 0ns} -radix bin   ;# CS de-asserted (high)
add_force [sig qspi_dat0] {0 0ns} -radix bin   ;# MOSI low
run 200ns                 ;# let the DUT settle

########################################################################
# Parameters
########################################################################
set Tclk   100ns          ;# 1 MHz period
set Thalf  50ns
set CMD    0x6B
set DUMMY  260             ;# number of EXTRA full clocks

########################################################################
# Begin transaction: pull CS low
########################################################################
add_force [sig qspi_cs] 0 -radix bin
run $Thalf                     ;# tSU(CS→CLK) – half a period

########################################################################
# Shift out 0x6B, MSB first.  Data is stable before the rising edge.
########################################################################
for {set i 7} {$i >= 0} {incr i -1} {
    set bitval [expr {($CMD >> $i) & 1}]
    add_force [sig qspi_dat0] $bitval -radix bin
    spi_tick $Thalf
}

########################################################################
# Hold MOSI low (or change to Z if you tri-state on reads)
########################################################################
add_force [sig qspi_dat0] 0 -radix bin

########################################################################
# Issue 1100 *extra* clock cycles for the read phase
########################################################################
for {set i 0} {$i < $DUMMY} {incr i} {
    spi_tick $Thalf
}

########################################################################
# De-assert CS high and run a little longer
########################################################################
add_force [sig qspi_cs] 1 -radix bin


# Wait a minute
for {set i 0} {$i < 10} {incr i} {
    spi_tick $Thalf
}

########################################################################
# Begin transaction: pull CS low
########################################################################
add_force [sig qspi_cs] 0 -radix bin
run $Thalf                     ;# tSU(CS→CLK) – half a period

########################################################################
# Shift out 0x6B, MSB first.  Data is stable before the rising edge.
########################################################################
for {set i 7} {$i >= 0} {incr i -1} {
    set bitval [expr {($CMD >> $i) & 1}]
    add_force [sig qspi_dat0] $bitval -radix bin
    spi_tick $Thalf
}

########################################################################
# Hold MOSI low (or change to Z if you tri-state on reads)
########################################################################
add_force [sig qspi_dat0] 0 -radix bin

########################################################################
# Issue 1100 *extra* clock cycles for the read phase
########################################################################
for {set i 0} {$i < $DUMMY} {incr i} {
    spi_tick $Thalf
}

run 2us
