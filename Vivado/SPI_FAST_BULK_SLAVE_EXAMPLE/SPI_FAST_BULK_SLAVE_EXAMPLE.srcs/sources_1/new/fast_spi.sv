// -----------------------------------------------------------------------------
//  Minimal MT25Q Quad-SPI NOR "black-box" emulator
//  ----------------------------------------------------------------------------
//  * Supports only two instructions the Linux SPI-NOR core absolutely needs:
//
//      0x9F  -  JEDEC ID READ      (returns 3-byte manufacturer + device code)
//      0x6B  -  QUAD OUTPUT FAST READ
//              (8-bit op-code, 24-bit address, 8 dummy cycles,
//               followed by endless data on 4 data lines)
//
//  * All other op-codes are ignored (MOSI bits are still swallowed).
//  * Data returned is the constant pattern 0xCAFEBABE_DEADBEEF, rotated
//    four bits every clock so it streams forever.
//
//  ⚠  This module is meant for *simulation / prototyping / FPGA firmware running
//     in a lab* - **not** for silicon production.  Timing, tri-state turn-around,
//     hold/setup margins, deep-power-down, write-enable, SFDP tables, etc.,
//     are *intentionally* omitted for clarity.
// -----------------------------------------------------------------------------

module top (
    // ---- Quad-SPI pins ------------------------------------------------------
    input  logic        qspi_clk,     // Serial clock from master (mode-agnostic)
    input  logic        qspi_cs,      // Chip-select, *active-LOW*
    inout  logic        qspi_dat0,    // IO0  - MOSI in 1-bit mode, bit-0 in x4
    inout  logic        qspi_dat1,    // IO1  - MISO in 1-bit mode, bit-1 in x4
    inout  logic        qspi_dat2,    // IO2  -             (unused in 1-bit)
    inout  logic        qspi_dat3,    // IO3  -             (unused in 1-bit)

    // ---- "spare" pins from the original template ---------------------------
    output logic        gnd,          // Hard-wired ZERO - makes PCB nets happy
    output logic        led,          // Heart-beat LED (blinks on any read)
    output logic        debug1,       // On logic analyzer
    output logic        debug2        // On logic analyzer
    
);

    // ---------------------------------------------------------------------
    //  Local parameters & convenience aliases
    // ---------------------------------------------------------------------
    localparam [7:0]  OPCODE_READ_ID  = 8'h9F;          // Read 24 bit device ID block
    localparam [7:0]  OPCODE_READ     = 8'h03;          // Read with address (default 24 bit address)
    localparam [7:0]  OPCODE_QOFR     = 8'h6B;          // Quad Output Fast Read
    
    
    // This is sent to the master when it issues OPCODE_READ_ID
    // Is there any way 
    localparam [31:0] JEDEC_ID        = {    
        //'h20,   //  Manufacturer=Micron
        8'h85,   //  TEST

        8'hBB,   //  Memory type=1.8V
        8'h22,   //  Capacity=2gb
        8'h00    // Num bytes remaing in this ID (non-standard) 
    };  
                                                        
    localparam [63:0] DATA_PATTERN    = 64'hCAFEBABE_DEADBEEF;

    // IO0 
    // in x1 mode, this is MOSI
    logic io0_out, io0_oe_pos, io0_oe_neg;
    assign qspi_dat0 = (io0_oe_pos & io0_oe_neg) ? io0_out : 1'bz;
    
    wire  io0_in     = qspi_dat0;

    // IO1 
    // in x1 mode this is MISO (an output)
    logic io1_out, io1_oe_pos, io1_oe_neg;
    assign qspi_dat1 = (io1_oe_pos & io1_oe_neg) ? io1_out : 1'bz;

    wire  io1_in     = qspi_dat1;

    // IO2 ------------------------------------------------------------------
    logic io2_out, io2_oe_pos, io2_oe_neg;
    assign qspi_dat2 = (io2_oe_pos & io2_oe_neg) ? io2_out : 1'bz;
    wire  io2_in     = qspi_dat2;

    // IO3 ------------------------------------------------------------------
    logic io3_out, io3_oe_pos, io3_oe_neg;
    assign qspi_dat3 = (io3_oe_pos & io3_oe_neg) ? io3_out : 1'bz;
    wire  io3_in     = qspi_dat3;

    // ---------------------------------------------------------------------
    //  Very small control state-machine
    // ---------------------------------------------------------------------
    typedef enum logic [2:0] {
        ST_CMD_CAPTURE   = 3'd1,   // Shifting in 8-bit op-code (this is default idle state)
        ST_SHIFT_TX1     = 3'd2,   // Shifting out what ever is in shift_out on dat1 forever
        ST_SHIFT_TX4     = 3'd3,   // Shifting out what ever is in shift_out on dat1 forever
                        
        ST_TOSS_A_CLKS   = 3'd4,   // Discard how ever many clocks are in bit_count (used for consuming address bits on read)
        ST_QOFR_DUMMY    = 3'd5,   // 8 dummy cycles before data phase
        ST_QOFR_DATA     = 3'd6,   // Infinite x4 data stream
        ST_DEAD          = 3'd7    // Do nothing, wait for a CS reset 
    } state_t;

    state_t state;
        
           
    // Whatever is in here goes out the door when in ST_SHIFT_OUT
    // Note we do not bother to keep a bit counter because if the master asks for more bits
    /// than we have, we mind as well send 0's, right?
    // sinlge bit SPI
    logic [63:0] shift_out_x1;
    
    // A define becuase I don't think a task or function can take
    // I know this is ugly, but I don't know a better way to pass a (compile-time) variable len packed array. Do you? 
    
    `define STUFF_INTO_SHIFT_OUT(x) shift_out_x1[ $high(shift_out_x1) -: $bits(x) ] <= x; bit_count <= $bits(x); io1_oe_pos <= 1'b1 
    
    // Quad shift out
    logic [63:0] shift_out_x4;
    
    // Incoming command byte
    logic [7:0] shift_in_x1;
    
    
    // a bit_counter, means didfferent things in different states
    // In ST_CMD_CAPTURE: This is number of command bits in shift_in_x1 so far (<8)   
    logic [5:0] bit_count;         // How many bits in shift_in_x1 so far?
    
    // Written to by posedge clk, read by negedge clk
    // we need this becuase the master reads MISO on the posedge
    logic next_bit_out;
    
    assign debug1 = (state == ST_SHIFT_TX1) ? 1'b1 : 1'b0; 
    assign debug2 = (state == ST_TOSS_A_CLKS) ? 1'b1 : 1'b0; 
    
    
    // When sending, we need to update our outputs on the negedge CLK so they will be ready for the master to sample on the posedge      
    always_ff @(negedge qspi_clk , posedge qspi_cs ) begin 
    
        if ( qspi_cs ) begin
        
            // CS deactive, so reset out half of the output enable            
            io0_oe_neg <= 1'b0;
            io1_oe_neg <= 1'b0;
            io2_oe_neg <= 1'b0;
            io3_oe_neg <= 1'b0;
            
        end else begin 
        
            // CS active 
    
            if (state == ST_SHIFT_TX1) begin
            
                // Our only job here is to get the next bit onto the pin on the negedge clk
                // everything else happens on the posedge to keep it in the same clk domain.
                 
                io1_out <= next_bit_out;
                io1_oe_neg <= 1'b1;                                     // Enable output on MOSI. Only matters on the 1st bit out the gate when we first enter this state, other passes will already be set  
                
            end else begin
            
                // Any non-transmit state? disable our half of the output enable. 
                io0_oe_neg <= 1'b0;
                io1_oe_neg <= 1'b0;
                io2_oe_neg <= 1'b0;
                io3_oe_neg <= 1'b0;
                
            end        
        end     
    end
        
    // I really want to make a task `load_shift_out( logic val[*] )` here, but I don't know how. Do you?


    // Main logic            
    always_ff @(posedge qspi_clk, posedge qspi_cs) begin
    
        if (qspi_cs) begin

            // If CS not asserted then we reset everything        
            state       <= ST_CMD_CAPTURE;      // Always reset to waiting for a command after CS deassertion. 
            bit_count     <= '0;                  // bits rx so far
            
            // All outputs high-Z
            io0_oe_pos <= 0; 
            io1_oe_pos <= 0; 
            io2_oe_pos <= 0; 
            io3_oe_pos <= 0;
            
        end else begin
        
            // CS is asserted
        
            case (state)

                ST_CMD_CAPTURE: begin
                
                    // Note this is a blocking assignment 
                    //logic next_shift_in_x1 =  {shift_in_x1[6:0], io0_in};
    
                    if (bit_count == 7 ) begin     
                    
                        // We read 7 bits, so with this current one we have all 8!

                        unique case ( {shift_in_x1[6:0], io0_in} ) 
                        
                            OPCODE_READ_ID:  begin
                            
                                // This command is the master asking us for our ID, so we send it.                              
                                
                                // BElow is overly ugly becuase we can not access the shift reg directly from the negedge clk always so we get everything ready here 
                                // Preload the first bit
                                next_bit_out = 1'b1; //  shift_out_x1[ $high(JEDEC_ID) ];
                    
                                shift_out_x1[ $high(shift_out_x1) -: 23 ] <= { 7'h01 , 8'h02 , 8'h03 };
                    
                                // stuff the rest of the bits into the shift register
                                //shift_out_x1[ $high(shift_out_x1) -: ($bits(JEDEC_ID)-1) ] <= { JEDEC_ID[ $high( JEDEC_ID ) -1 : 0]  };
                                
                                // Enable our half of the output enable. The negedge clk will enable the other half and then the pin will be output
                                io1_oe_pos <= 1'b1;
                                                                                                        
                                // switch to sending mode
                                state <= ST_SHIFT_TX1;
                                
                                // Note that we do not actually put the bit on the pin, and we do not set the pin for output,
                                // those happen in the always posedge clk abvove.  
                                        
                            end
                            
                            OPCODE_READ:  begin
                            
                                // This command is the master asking us for some data, but first we need to get rid of the 24 address bits.
                                bit_count <= 24;                                                              
                                state <= ST_TOSS_A_CLKS;
                                                                        
                            end
                            
    //                        OPCODE_QOFR:      state <= ST_QOFR_ADDR;
                            default:          state <= ST_DEAD; // Unsupported op, go dead wait for next CS reset
                            
                        endcase
  
  
                                                             
                     end else begin // else if (bit_count == 3'd7) begin 
                                          
                        shift_in_x1 <= {shift_in_x1[ $high(shift_in_x1) - 1 :0], io0_in};
                        bit_count   <= bit_count + 1;
                                         
                    end // if (bit_count == 3'd7) begin 
                    
                    
                end // ST_CMD_CAPTURE
                
                
                ST_SHIFT_TX1: begin
                
                    // always send next bit. note the bit will actually be put out the pin on the posedge clk by an always block above.
                    // no count, will keep sending over and over again forever.
                    next_bit_out =   shift_out_x1[ $high(shift_out_x1) ];
                    shift_out_x1 <= shift_out_x1 << 1;
                    
                end
                
                ST_TOSS_A_CLKS: begin
                
                    if (bit_count == 1 ) begin
                    
                        // we test for 1 rather than 0 becuase we are on the rising edge of the clk, so cnt not updated yet
                    
                        // We are done reading the address bits, so start sending the data!
                                                
                        // TODO: THIS SHOULD BE MACRO
                        
                        // Preload the first bit
                        next_bit_out =   shift_out_x1[ $high(DATA_PATTERN) ];
                
                        // stuff the rest of the bits into the shift register                                                      
                        shift_out_x1[ $high(shift_out_x1) -: ($bits(DATA_PATTERN)-1) ] <= { DATA_PATTERN[ $high( DATA_PATTERN ) -1 : 0]  };
                        
                        // Enable our half of the output enable. The negedge clk will enable the other half and then the pin will be output
                        io1_oe_pos <= 1'b1;
                                                                                                
                        // switch to sending mode
                        state <= ST_SHIFT_TX1;
                                                
                    end else begin
                    
                        bit_count <= bit_count - 1;
                        
                    end //  if (bit_count == 1 ) begin
                                    
                end // ST_TOSS_A_CLKS:
    
            endcase //  case (state)
                  
        end // els of if (qspi_cs)
            
    end // always_ff @(posedge qspi_clk, posedge qspi_cs) begin

    
    // LED heartbeat ---------------------------------------------------------
    always_ff @(posedge qspi_clk) begin
        if (state == ST_QOFR_DATA)
            led <= ~led;          // Blink while streaming data
    end

    // gnd pin is always tied low -------------------------------------------
    assign gnd = 1'b0;
       
     
endmodule
