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

   localparam int SR_WIDTH = 1024;
                   
    // For now, first the enable bits, then the data bits in one shoft reg
    // 40 = 8 command, 24 address, 8 dummy
           
    logic [ $clog2(SR_WIDTH) :0] count =0; 
    
    localparam DATA_PATTERN  = {
        40'b0,                                      // These are dummy bits that will get dumped as we consume the command, address, and dummy clock cycles. 
        'hff00ff00_cafebabe_01234567_deadbeef,
        'hff00ff00_cafebabe_01234567_deadbeef,
        'hff00ff00_cafebabe_01234567_deadbeef,
        'hff00ff00_cafebabe_01234567_deadbeef               
    };

    logic [0:$high(DATA_PATTERN)] sr = DATA_PATTERN;  
                  
    assign qspi_dat1 = (!qspi_cs) && (count >= 40 ) ? sr[count] : 1'bz;
    
    assign debugA = (count >= 40 );
    assign debugB = sr[count];
    
    assign active_cs_and_clk_high = (!qspi_cs) && qspi_clk;
    
    assign inactive_cs_and_clk_low = (!qspi_cs) && (!qspi_clk); 
                         
    always @( negedge active_cs_and_clk_high or posedge qspi_cs )  begin
    
        count <= qspi_cs ? 0 : count +1;
                                 
    end
            
    // LED on when we are active
    assign led = 1'b1;
    
    // gnd pin is always tied low for convienice
    assign gnd = 1'b0;
       
     
endmodule
