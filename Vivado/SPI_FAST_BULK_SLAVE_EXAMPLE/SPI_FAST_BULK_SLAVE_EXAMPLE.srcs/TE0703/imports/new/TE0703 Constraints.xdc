#### These values are for the TE0703 carrier board
#### Tried to match the Voyant PCB when possible, but when not possible picked easy to access pins.


## CLK

# On Dhalia this comes out on X19-4 
# Connects to FPGA pin Y12
# On TE0703 carrier comes on J2-B8

# J2-B8
set_property PACKAGE_PIN    K17         [get_ports {qspi_clk}]    
set_property IOSTANDARD     LVCMOS18    [get_ports {qspi_clk}]

# Tell Vivado the frequency (period = 50 ns for 20 MHz)
create_clock \
    -name clk                        \
    -period 40.000                   \
    -waveform {0 20}                 \
    [get_ports qspi_clk]

## CS

# On the SOM this is called signal QSPI_SSN 
# On Dhalia this comes out on X19-5
# It goes into the TE0712 module on B_15_L22_P which maps to pin  L15
# On TE0703 carrier board at header  J2-B6

# J2-B6
set_property PACKAGE_PIN    L15         [get_ports {qspi_cs}]  
set_property IOSTANDARD     LVCMOS18    [get_ports {qspi_cs}]

# DATA PINS

# J2-A6
set_property PACKAGE_PIN    M15         [get_ports {qspi_dat0}]     
set_property IOSTANDARD     LVCMOS18    [get_ports {qspi_dat0}]

# J2-A7
set_property PACKAGE_PIN    M16         [get_ports {qspi_dat1}]           
set_property IOSTANDARD     LVCMOS18    [get_ports {qspi_dat1}]

# J2-A8
set_property PACKAGE_PIN    H17         [get_ports {qspi_dat2}]     
set_property IOSTANDARD     LVCMOS18    [get_ports {qspi_dat2}]

# J2-A9
set_property PACKAGE_PIN    H18         [get_ports {qspi_dat3}]     
set_property IOSTANDARD     LVCMOS18    [get_ports {qspi_dat3}]


# J2-B9
set_property PACKAGE_PIN M22        [get_ports    debugA]
set_property IOSTANDARD  LVCMOS18   [get_ports    debugA]

# J2-B10
set_property PACKAGE_PIN N22        [get_ports    debugB]
set_property IOSTANDARD  LVCMOS18   [get_ports    debugB]



# 1. Tell synthesis not to add a BUFG becuase this clock is completely external
#    and we only need it here for ourselves.  
# set_property CLOCK_BUFFER_TYPE NONE [get_ports {qspi_clk}]

# GND #

# Here we make a synthentic ground just to have a connvienent place to 
# connect debug tools to that is near the other pins.

# J2-B7
set_property PACKAGE_PIN    J17         [get_ports {gnd}]  
set_property IOSTANDARD     LVCMOS18    [get_ports {gnd}]
set_property PULLTYPE       PULLDOWN    [get_ports {gnd}]

# LED D4  (green)  - JB2-90 → FPGA pin J16  (bank 15, 3.3 V default on TE0703)

set_property PACKAGE_PIN J16        [get_ports    led]
set_property IOSTANDARD  LVCMOS18   [get_ports    led]

# Some handy debug ports to connect logic analyzer to


# Nessisary to avoid warnings about the always blocks on both pos and neg of clk
# set_clock_groups -asynchronous -group {qspi_clk} -group {qspi_clk_falling}