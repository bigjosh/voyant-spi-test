
######
# CS #
######

# Finally we need the chip select. This comes from the MCU and starts a 
# new data frame from the FPGA side. When the FPGA sees this go high,
# it will start sending at the begining of a new frame.

# On the MCU, this is called FPGA_SPI_SSN
# It goes into the FPGA on B_15_L22_P which maps to pin  L15
# On carrier board at header  J2-B6

set_property PACKAGE_PIN    L15         [get_ports {qspi_cs}]  
set_property IOSTANDARD     LVCMOS18    [get_ports {qspi_cs}]


# MOSI 
set_property PACKAGE_PIN    M15         [get_ports {qspi_dat0}]     
set_property IOSTANDARD     LVCMOS18    [get_ports {qspi_dat0}]

# MULTI_SPI_MISO is on signal B15_L24_N directly from the Voyant schematic
# This is FPGA pin M16
# Appears on the Trenz TE0703 carrier on header J2-A7

# MISO 
set_property PACKAGE_PIN    M16         [get_ports {qspi_dat1}]     
set_property IOSTANDARD     LVCMOS18    [get_ports {qspi_dat1}]

set_property PACKAGE_PIN    W14         [get_ports {qspi_dat2}]     
set_property IOSTANDARD     LVCMOS18    [get_ports {qspi_dat2}]

set_property PACKAGE_PIN    AB13        [get_ports {qspi_dat3}]     
set_property IOSTANDARD     LVCMOS18    [get_ports {qspi_dat3}]


#######
# CLK #
#######

# Next we need the SPI clock. this will come form the MCU and clock out the 
# bits from the FPGA.

# We will switch to this when loading the test program onto the Voyant PCB
# but someone should double check this PACKAGE_PIN is correct, and also the IOSTANDARD

# This is where the MCU MULTI_SPI_CLK connects to the FPGA based on the 
# Voyant PCB and the Trendz spreadsheet. Currently output from MCU as master
# and input to FPGA, although would be better to have the FPGA be master,
# but a little scary becuase they could somehow both end up driving that line 
# at the same time and that would be bad. 
#set_property PACKAGE_PIN   Y11         [get_ports {multi_spi_clk}]     
#set_property IOSTANDARD    LVCMOS18    [get_ports {multi_spi_clk}]

# We will use this temporarily as the clock input becuase the clock input
# pin on the voyant board is not accessable on the Tranez carrier board.
# We picked this pin becuase it is no-connection on the Voyant PCB so
# no damage in case wrong code gets installed. It is also near the other pins
# on the carrier board header J2. 
# Change this when moving to the Voyany PCB 
# Appears on the Trenz TE0703 carrier on header J2-B8

# TODO: FIX THIS

#set_property PACKAGE_PIN    M22         [get_ports {multi_spi_clk}]  
# set_property IOSTANDARD     LVCMOS18    [get_ports {multi_spi_clk}]
# J2-B8
set_property PACKAGE_PIN    K17         [get_ports {qspi_clk}]    
set_property IOSTANDARD     LVCMOS18    [get_ports {qspi_clk}]


# 1. Tell synthesis not to add a BUFG becuase this clock is completely external
#    and we only need it here for ourselves.  
set_property CLOCK_BUFFER_TYPE NONE [get_ports {qspi_clk}]

######
# CS #
######

# Finally we need the chip select. This comes from the MCU and starts a 
# new data frame from the FPGA side. When the FPGA sees this go high,
# it will start sending at the begining of a new frame.

# On the MCU, this is called FPGA_SPI_SSN
# It goes into the FPGA on B_15_L22_P which maps to pin  L15
# On carrier board at header  J2-B6

set_property PACKAGE_PIN    L15         [get_ports {qspi_cs}]  
set_property IOSTANDARD     LVCMOS18    [get_ports {qspi_cs}]



#######
# GND #
#######

# Here we make a synthentic ground just to have a connvienent place to 
# connect debug tools to that is near the other pins.

set_property PACKAGE_PIN    J17         [get_ports {gnd}]  
set_property IOSTANDARD     LVCMOS18    [get_ports {gnd}]
set_property PULLTYPE       PULLDOWN    [get_ports {gnd}]

###############################################################################
# LED D4  (green)  - JB2-90 → FPGA pin J16  (bank 15, 3.3 V default on TE0703)
###############################################################################
set_property PACKAGE_PIN J16        [get_ports    led]
set_property IOSTANDARD  LVCMOS18   [get_ports    led]

# J2-A8
set_property PACKAGE_PIN H17        [get_ports    debug1]
set_property IOSTANDARD  LVCMOS18   [get_ports    debug1]

# J2-A9
set_property PACKAGE_PIN H18        [get_ports    debug2]
set_property IOSTANDARD  LVCMOS18   [get_ports    debug2]

