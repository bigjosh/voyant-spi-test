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
    localparam [7:0]  OPCODE_JEDEC_ID = 8'h9F;
    localparam [7:0]  OPCODE_QOFR     = 8'h6B;          // Quad Output Fast Read
    localparam [23:0] JEDEC_ID        = 24'h20_BA_19;   // Micron 128-Mbit example
                                                        //  0x20 = Manufacturer
                                                        //  0xBA = Memory type
                                                        //  0x19 = Capacity
                                                        
                                                        
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
        
        ST_QOFR_ADDR     = 3'd4,   // Capturing 24-bit address (discarded)
        ST_QOFR_DUMMY    = 3'd5,   // 8 dummy cycles before data phase
        ST_QOFR_DATA     = 3'd6,   // Infinite x4 data stream
        ST_DEAD          = 3'd7    // Do nothing, wait for a CS reset 
    } state_t;

    state_t state;
        
           
    // Whatever is in here goes out the door when in ST_SHIFT_OUT
    // Note we do not bother to keep a bit counter because if the master asks for more bits
    /// than we have, we mind as well send 0's, right?
    // sinlge bit SPI
    logic [31:0] shift_out_x1;
    
    `define STUFF_INTO_SHIFT_OUT(x) shift_out_x1[ $high(shift_out_x1) -: $bits(x) ] <= x

    
    // Quad shift out
    logic [63:0] shift_out_x4;
    
    // Incoming command byte
    logic [7:0] shift_in_x1;
    
    
    // a bit_counter, means didfferent things in different states
    // In ST_CMD_CAPTURE: This is number of command bits in shift_in_x1 so far (<8)   
    logic [4:0] bit_cnt;         // How many bits in shift_in_x1 so far?
    
    // Written to by posedge clk, read by negedge clk
    // we need this becuase the master reads MISO on the posedge
    logic next_bit_out;
    
    assign debug1 = shift_in_x1[0];    
    assign debug2 = shift_in_x1[1];
    
    
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
            
                // Our only job here is to get the next bit onto the pin on the posedge clk
                // everything else happens on the negedge to keep it in the same clk domain.
                 
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
            bit_cnt     <= '0;                  // bits rx so far
            
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
    
                    if (bit_cnt == 3'd7) begin     
                    
                        // We read 7 bits, so with this current one we have all 8!

                        unique case ( {shift_in_x1[6:0], io0_in} ) 
                        
                            OPCODE_JEDEC_ID:  begin
                            
                                // This command is the master asking us for our ID, so we send it.                              
                                
                                // Preload the first bit
                                next_bit_out =   shift_out_x1[ $high(shift_out_x1) ];
                    
                                // stuff the rest of the bits into the shift register                                                      
                                shift_out_x1[ $high(shift_out_x1) -: ($bits(JEDEC_ID)-1) ] <= { JEDEC_ID[ $high( JEDEC_ID ) : 0]  };
                                
                                // Enable our half of the output enable. The posedge clk will enable the other half and then the pin will be output
                                io1_oe_pos <= 1'b1;
                                                                                                        
                                // switch to sending mode
                                state <= ST_SHIFT_TX1;
                                
                                // Note that we do not actually put the bit on the pin, and we do not set the pin for output,
                                // those happen in the always posedge clk abvove.  
                                        
                            end
                                                        
                            
    //                        OPCODE_QOFR:      state <= ST_QOFR_ADDR;
                            default:          state <= ST_DEAD; // Unsupported op, go dead wait for next CS reset
                            
                        endcase
  
  
                                                             
                     end else begin // else if (bit_cnt == 3'd7) begin 
                     
                        shift_in_x1 <= {shift_in_x1[6:0], io0_in};
                        bit_cnt   <= bit_cnt + 1;
                                         
                    end // if (bit_cnt == 3'd7) begin 
                    
                    
                end // ST_CMD_CAPTURE
                
                
                ST_SHIFT_TX1: begin
                
                    // always send next bit. note the bit will actually be put out the pin on the posedge clk by an always block above.
                    next_bit_out =   shift_out_x1[ $high(shift_out_x1) ];
                    shift_out_x1 <= shift_out_x1 << 1;
                    
                end
    
    /*
                // ---------------------------------------------------------
                ST_QOFR_ADDR: begin
                    // Swallow 24 address bits on IO0; nothing is driven
                    bit_cnt <= bit_cnt + 1;
                    if (bit_cnt == 5'd23) begin
                        state   <= ST_QOFR_DUMMY;
                        bit_cnt <= '0;
                    end
                end
        
                // ---------------------------------------------------------
                ST_QOFR_DUMMY: begin
                    // Wait 8 "dummy" clock cycles (one per incoming bit)
                    bit_cnt <= bit_cnt + 1;
                    if (bit_cnt == 3'd7) begin
                        state   <= ST_QOFR_DATA;
                        bit_cnt <= '0;
        
                        // Enable all 4 IO outputs for quad data
                        io0_oe <= 1; io1_oe <= 1; io2_oe <= 1; io3_oe <= 1;
                    end
                end
        
                // ---------------------------------------------------------
                ST_QOFR_DATA: begin
                    // Present the *upper nibble* of data_shift on IO3:IO0
                    {io3_out, io2_out, io1_out, io0_out} <= data_shift[63:60];
        
                    // Rotate left by 4 bits (nibble) so pattern streams forever
                    data_shift <= {data_shift[59:0], data_shift[63:60]};
                    // (No exit condition - master will raise CS_N when finished)
                end
        
                // ---------------------------------------------------------
                default: state <= ST_IDLE; // Shouldn't happen - safety net
                
*/                
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
