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
                   
    
    localparam JEDEC_ID = {
        8'h20,   //  Manufacturer=Micron
        8'hBB,   //  Memory type=1.8V
        8'h17,   //  Capacity=16Mb = 8MB. This is small enough that the driver will only use 3-byte addressing, saving us a byte on each transaction. 
        8'h00    //  Num bytes remaing in this ID (non-standard, but works with spi-nor driver) 
    };
      
    // Time for us to get the leading command from master 
    localparam [ 7:0]  command_rx_x1= 8'b0;      
    
    // What will will send back to a DEVICE ID command request  
    localparam [ $bits(   JEDEC_ID ) -1 : 0 ] device_id_response_x1 = {
        JEDEC_ID
    };
        

    // These are filler bits that will get dumped as we consume the command, address, and dummy clock cycles. (command( 8 / 1 bit MOSI) + address(24 bits / 4 quad lines) + dummy(8) )
    // This is long enoug for the ^B read quad command     
    localparam int FILLER_BITS = (8 + (24/4) + 8);     //             

    // Add enough padding at the end so we are at the full length of everything the master sends with a 6B read command.  
    localparam [  FILLER_BITS - $bits( command_rx_x1 ) - $bits( device_id_response_x1 ) - 1 : 0 ] padding_x1 = 0;
    
    localparam header_x1 = {
    
        command_rx_x1,
        device_id_response_x1,
        padding_x1
        
    };
    
     localparam int HEADER_BITS = $bits(  header_x1 ); 

    // Spread the bits out so they land on the dat1 (MISO) line
    //      src  = ABCDE
    //      dst  = 0A000B000C000D000E00
        
    function automatic logic [HEADER_BITS*4-1:0] spread_header_bits;

        logic [HEADER_BITS*4-1:0] dst = '0;        // initialise to all-zeros
        for (int i = 0; i < HEADER_BITS; i++)
            dst[ (i*4) +1 ] = header_x1[i];              // drop each header bit into bit 1 of the corresponding nibble in the output  
        return dst;
    endfunction    

    // Some easy to eyebal test data to go into the packet
              
    localparam DATA_PATTERN  = {    
        256'h1248ff00_cafebabe_01234567_deadbeef,
        256'hff00ff00_cafebabe_01234567_deadbeef,
        256'hff00ff00_cafebabe_01234567_deadbeef,
        256'hff00ff00_cafebabe_01234567_deadbeef               
    };
        
    logic [ $bits(spread_header_bits()) + $bits(DATA_PATTERN) -1 :0] sr = {        
        spread_header_bits(),
        DATA_PATTERN
    };
                      
    
    // For now, first the enable bits, then the data bits in one shoft reg
    // 40 = 8 command, 24 address, 8 dummy
           
    logic [ $clog2($bits(DATA_PATTERN)):0] negedge_clk_count =0;
    
    
    logic [0 : HEADER_BITS-1 ] shift_in;     // need enough bits so we can hold everything we need  
    
    // map the current 4 dat lines from the sr to the output pins
    wire [3:0] quad_out = sr[ ($high(sr) -  ( negedge_clk_count * 4 )) -: 4 ];
    
    // assign quad_out 
    

    // Are we enabled to send after the master has finished everything it needs to send at the begining of a 6B read?
    wire tx_enabled      = ( negedge_clk_count >= HEADER_BITS );
    
    // Are we enabled to send after the master has finished everything it needs to send at the begining of a 9F read device id?
    // and did we actually get a read device id command?    
    wire recevied_dev_id_flag = ( negedge_clk_count >= 8) && (shift_in[ 0:7]  == 8'h9f ) ; 
    wire tx_miso_enabled = tx_enabled || recevied_dev_id_flag;  
             
    
    assign qspi_dat0 = (!qspi_cs) && tx_enabled ? quad_out[0] : 1'bz;      
    
    
    // dat1 is special becuase it is MISO so we use this to send data when we are in 1 bit mode responding to a device id command              
    assign qspi_dat1 = (!qspi_cs) && tx_miso_enabled ? quad_out[1] : 1'bz;
    
                      
    assign qspi_dat2 = (!qspi_cs) && tx_enabled ? quad_out[2] : 1'bz;                  
    assign qspi_dat3 = (!qspi_cs) && tx_enabled ? quad_out[3] : 1'bz;                  
    
    //assign debugA = ( past_dummy_bits_flag );
    
    assign debugA = ( tx_enabled );    
    assign debugB = (tx_miso_enabled );            // JDEC ID COMMAND
    
    assign active_cs_and_clk_high = (!qspi_cs) && qspi_clk;    
    assign inactive_cs_and_clk_low = (!qspi_cs) && (!qspi_clk);

    assign not_qspi_clk = ~ qspi_clk;
    assign not_qspi_cs  = ~ qspi_cs;
    
    // I _need_ the synthesizer to infer this is a counter with reset, so I make the motif look *excactly* like the reference example.
        
    always @( negedge (!qspi_clk || qspi_cs)  )  begin     // negedge qspi_clk
    
        // actually posedge qspi_clk or negedge qspi_cs
        
        // The first posedge clk after a negedge cs should have count = 0

        // first posedge comes first, so negedge counter will be 0 here on posedge
        
        // Caputre the beginging of the burst so we can check for command and maybe other things.         
                
        // Only fill the shift_in vector once per CS transaction. 
        shift_in[negedge_clk_count] <= (negedge_clk_count < HEADER_BITS ) ? qspi_dat0 : shift_in[negedge_clk_count];
        
        
        
    
    end
        
                         
    always @( posedge (!qspi_clk || qspi_cs)  )  begin     // negedge qspi_clk
    
        // actually negedge qspi_clk or posedge qspi_cs
    
        if ( qspi_cs )
            // posedge of cs, so reset counter. could also be a clock while we are not active, who cares
            negedge_clk_count <= 0;
        else 
            negedge_clk_count <= negedge_clk_count + 1;
                                                         
    end
            
    // LED on when we are active
    assign led = 1'b1;
    
    // gnd pin is always tied low for convienice
    assign gnd = 1'b0;
       
     
endmodule
