//  Minimal MT25Q Quad-SPI NOR  emulator
//  Supports only two commands:
//
//      0x9F  -  READ ID
//      0x6B  -  QUAD OUTPUT FAST READ
// 
// The READ ID is needed durring boot up for the kernel to know to load the driver.  
// The QUAD READ is what the kernel then uses to read actual data from us.
//
// EVERYTHING ELSE is brutally ignored. The address bits in the QUAD READ are bruttally ignored.
//
// We picked a chip to emulate that the kernal has a table for, and in that table it knows to use fast quad reads. 

module simplest (
    // Quad-SPI pins 
    input  wire        qspi_clk,     // Serial clock from master (mode-agnostic)
    input  wire        qspi_cs,      // Chip-select, *active-LOW*
    inout  wire        qspi_dat0,    // IO0  - MOSI in 1-bit mode, bit-0 in x4
    output wire        qspi_dat1,    // IO1  - MISO in 1-bit mode, bit-1 in x4
    output wire        qspi_dat2,    // IO2  -             (unused in 1-bit)
    output wire        qspi_dat3,    // IO3  -             (unused in 1-bit)

    // Extras to make work easier
    output wire        gnd,          // Hard-wired ZERO - makes PCB nets happy
    output wire        led,          // Heart-beat LED (blinks on any read)
    output wire        debugA,       // On logic analyzer
    output wire        debugB        // On logic analyzer
    
);

    assign debugA = qspi_cs;
    assign debugV = qspi_clk;
    

    // LED on when we are active
    assign led = 1'b0;
    
    // gnd pin is always tied low for convienice
    assign gnd = 1'b0;
       
     
endmodule
