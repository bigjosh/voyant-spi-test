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
    output logic        debugA,       // On logic analyzer
    output logic        debugB        // On logic analyzer
    
);

    // ---------------------------------------------------------------------
    //  Local parameters & convenience aliases
    // ---------------------------------------------------------------------
    localparam [7:0]  OPCODE_READ_ID    = 8'h9F;          // Read 24 bit device ID block
    localparam [7:0]  OPCODE_READ       = 8'h03;          // Read with address (default 24 bit address)
    localparam [7:0]  OPCODE_QOFR       = 8'h6B;          // Quad Output Fast Read
        
    // This is sent to the master when it issues OPCODE_READ_ID
    // Taken from datasheet page 34 
    localparam [31:0] JEDEC_ID        = {    
        8'h20,   //  Manufacturer=Micron
        8'hBB,   //  Memory type=1.8V
        8'h17,   //  Capacity=16Mb = 8MB. This is small enough that the driver will only use 3-byte addressing, saving us a byte on each transaction. 
        8'h00    //  Num bytes remaing in this ID (non-standard, but works with spi-nor driver) 
    };  
    
    
/*

    // Alternate part just in case
    
    localparam [31:0] JEDEC_ID        = {    
        8'hef,   //  Manufacturer=Winbond W25Q128
        8'h40,   //  Memory type=1.8V
        8'h18,   //  Capacity=2gb
        8'h00    // Num bytes remaing in this ID (non-standard) 
    };  
        
*/                                                        
//    localparam [63:0] DATA_PATTERN    = 64'hCAFEBABE_DEADBEEF;
    localparam [127:0] DATA_PATTERN    = 128'h01234567_89ABCDEF_FEDCBA98_76543210;
    
    
    // Are we driving pins? Both of these need to be enabled for pins to be output. 
    logic output_enable_pos;
    logic output_enable_neg;

    // IO0 
    // in x1 mode, this is MOSI
    logic io0_out;
    assign qspi_dat0 = (output_enable_pos && output_enable_neg ) ? io0_out : 1'bz;
    
    wire  io0_in     = qspi_dat0;

    // IO1 
    // in x1 mode this is MISO (an output)
    logic io1_out;
    assign qspi_dat1 = (output_enable_pos && output_enable_neg ) ? io1_out : 1'bz;

    wire  io1_in     = qspi_dat1;

    // IO2 ------------------------------------------------------------------
    logic io2_out;
    assign qspi_dat2 = (output_enable_pos && output_enable_neg ) ? io2_out : 1'bz;
    wire  io2_in     = qspi_dat2;

    // IO3 ------------------------------------------------------------------
    logic io3_out;
    assign qspi_dat3 = (output_enable_pos && output_enable_neg ) ? io3_out : 1'bz;
    wire  io3_in     = qspi_dat3;

    // ---------------------------------------------------------------------
    //  Very small control state-machine
    // ---------------------------------------------------------------------
    typedef enum logic [2:0] {
        ST_CMD_CAPTURE   = 3'd1,   // Shifting in 8-bit op-code (this is default idle state)
        ST_SHIFT_TX1     = 3'd2,   // Shifting out what ever is in shift_out on dat1 forever
        ST_SHIFT_TX4     = 3'd3,   // Shifting out what ever is in shift_out on dat[0:3] forever                        
        ST_READ_1X_DUMMY = 3'd4,   // Discard how ever many clocks are in bit_count then go to ST_SHIFT_TX1 (used for consuming address bits on read)
        ST_READ_4X_DUMMY = 3'd5,   // Discard how ever many clocks are in bit_count then go to ST_SHIFT_TX4 (used for consuming address bits on read)
        ST_DEAD          = 3'd7    // Do nothing, wait for a CS reset 
    } state_t;

    state_t state = ST_CMD_CAPTURE;
        
           
    // Whatever is in here goes out the door when in ST_SHIFT_OUT
    // Note we do not bother to keep a bit counter because if the master asks for more bits
    /// than we have, we mind as well send 0's, right?
    // sinlge bit SPI
    logic [127:0] shift_out_x1;
    
    // A define becuase I don't think a task or function can take
    // I know this is ugly, but I don't know a better way to pass a (compile-time) variable len packed array. Do you? 
    
    //`define STUFF_INTO_SHIFT_OUT(x) shift_out_x1[ $high(shift_out_x1) -: $bits(x) ] <= x; bit_count <= $bits(x); io1_oe_pos <= 1'b1 
        
    // Incoming command byte
    logic [7:0] shift_in_x1;
    
    
    // a bit_counter, means didfferent things in different states
    // In ST_CMD_CAPTURE: This is number of command bits in shift_in_x1 so far (<8)  
    // In ST_READ_Xx_DUMMY: This is the number of dummy bits to read before switching to READ state 
    logic [7:0] bit_count = 0;         // How many bits in shift so far?
        
    // Written to by posedge clk, read by negedge clk
    // we need this becuase the master reads MISO on the posedge
    // TODO: This could be smaller (and could overflow). What is the right way to allocate this size?    
    logic [3:0] next_quad_out;
    
    // Are we currently transmitting?
    // This just makes it so we don't need to keep track of which states are transmit states here. Better to know that 
    // close to where those states are enetered. 
    // used in posedge clk to output next bits (also enables the outputs if they are not alreday enabled)
    logic tx_flag =1'b0;


    //    assign debugA = qspi_clk;
    assign debugA = tx_flag;
    assign debugB = (state == ST_READ_4X_DUMMY ) ? 1'b1 : 1'b0;
    
                 
    // When sending, we need to update our outputs on the negedge CLK so they will be ready for the master to sample on the posedge      
    always_ff @(negedge qspi_clk ,  posedge qspi_cs ) begin
    
        if (qspi_cs) begin 
            
            // We got deselected. 
            
            output_enable_neg <= 0; 
                         
    
        end else begin
                            
            // CS active 
            
            if ( tx_flag ) begin
            
                // TODO: Do not drive the da0 in 1 bit mode. 
            
                output_enable_neg <= 1'b1;
                 
                io0_out <= next_quad_out[0];
                io1_out <= next_quad_out[1];
                io2_out <= next_quad_out[2];
                io3_out <= next_quad_out[3];
                              
            end
        end     
    end
    
    logic powerup_flag = 1'b1; 
    
    // Main logic            
    always_ff @(posedge qspi_clk , posedge qspi_cs ) begin
    
        if (qspi_cs || powerup_flag ) begin
        
            // CS high so we have been deselected. we need to reset everything and get red for next trasnaction.
                
            // imedeately tri-state the oouts so other people can use the bus
            // better to put a `& ~qspi_cs` into the assign? 
            output_enable_pos <= 1'b0;
            tx_flag <= 1'b0;                    
            state       <= ST_CMD_CAPTURE;      // Always reset to waiting for a command after CS deassertion.
            bit_count   <= 0;
            powerup_flag <= 1'b0;
            
        end else begin                                                  
                 
            // CS is asserted and we are already actively doing stuff since the last negedge cs
        
            case (state)

                ST_CMD_CAPTURE: begin
                
                    // Note this is a blocking assignment 
                    //logic next_shift_in_x1 =  {shift_in_x1[6:0], io0_in};
    
                    if (bit_count == 7 ) begin     
                    
                        // We read 7 bits, so with this current one we have all 8!

                        unique case ( {shift_in_x1[6:0], io0_in} ) 
                        
                            OPCODE_READ_ID:  begin
                            
                                // This command is the master asking us for our ID, so we send it.                              
                                
                                // Below is overly ugly becuase we can not access the shift reg directly from the negedge clk always so we get everything ready here 
                                // Preload the first bit. Dont care about the other dat pins we are in 1x mode now. 
                                next_quad_out[0] <= JEDEC_ID[ $high(JEDEC_ID) ];
                    
                                // stuff the rest of the bits into the shift register
                                shift_out_x1[ $high(shift_out_x1) -: ($bits(JEDEC_ID)-1) ] <= { JEDEC_ID[ $high( JEDEC_ID ) -1 : 0]  };
                                
                                // switch to sending mode. We will send this bit and enable the outputs on next negedge clk
                                state <= ST_SHIFT_TX1;
                                tx_flag <= 1'b1;                    
                                
                                output_enable_pos <= 1'b1;
                                                                        
                            end
                            
                            OPCODE_READ:  begin
                            
                                // This command is the master asking us for some data, but first we need to get rid of the 24 address bits.
                                bit_count <= 24 ;               // ignore 3 address bytes                                                          
                                state <= ST_READ_1X_DUMMY;
                                                                        
                            end
                            
                            OPCODE_QOFR:  begin
                            
                                // This command is the master asking us for some data on quad IO lines, but first we need to get rid of the 24 address bits + 8 dummy bits
                                bit_count <= (3*8) + (8) ;    // 3 address bytes + 8 dummy bits. TODO: We can get rid of the dummies by implementing the capabilities table.                                                               
                                state <= ST_READ_4X_DUMMY;
                                                                        
                            end
                                                        
                            
    //                        OPCODE_QOFR:      state <= ST_QOFR_ADDR;
                            default: begin
                            
                              state <= ST_DEAD; // Unsupported op, go dead wait for next CS reset
                              tx_flag <= 1'b0;
                              output_enable_pos <= 1'b0;
                              
                            end
                                                         
                        endcase // command recieved (if we fall though this case then the command is ignored. 
                                                                 
                     end else begin // else if (bit_count == 3'd7) begin 
                     
                        // Keep reading/shifting in current command
                                          
                        shift_in_x1 <= {shift_in_x1[ $high(shift_in_x1) - 1 :0], io0_in};
                        bit_count   <= bit_count + 1;
                                         
                    end // if (bit_count == 3'd7) begin 
                    
                    
                end // ST_CMD_CAPTURE
                
                
                ST_SHIFT_TX1: begin
                
                    // always send next bit. note the bit will actually be put out the pin on the posedge clk by an always block above.
                    // no count, will keep sending over and over again forever.
                    next_quad_out[1] <=   shift_out_x1[ $high(shift_out_x1) ];
                    shift_out_x1 <= shift_out_x1 << 1;
                    
                    
                end
                
                ST_SHIFT_TX4: begin
                
                    // always send next bit. note the bit will actually be put out the pin on the posedge clk by an always block above.
                    // no count, will keep sending over and over again forever.
                    next_quad_out <=   shift_out_x1[ $high(shift_out_x1) -: 4 ];
                    shift_out_x1 <= shift_out_x1 << 4;
                    
                end
                
                
                ST_READ_1X_DUMMY: begin
                
                    if (bit_count == 1 ) begin
                    
                        // we test for 1 rather than 0 becuase we are on the rising edge of the clk, so cnt not updated yet
                    
                        // We are done reading the address bits, so start sending the data!
                                                
                        // TODO: THIS SHOULD BE MACRO
                        
                        // Preload the first bit
                        next_quad_out[0] <=   DATA_PATTERN[ $high(DATA_PATTERN) ];
                
                        // stuff the rest of the bits into the shift register                                                      
                        shift_out_x1[ $high(shift_out_x1) -: ($bits(DATA_PATTERN)-1) ] <= { DATA_PATTERN[ $high( DATA_PATTERN ) -1 : 0]  };
                        
                        // switch to sending mode. the posedge clk will see this state and enable output and send the bits
                        state <= ST_SHIFT_TX1;
                        output_enable_pos <= 1'b1;
                        tx_flag <= 1'b1;
                                                                        
                    end else begin
                    
                        bit_count <= bit_count - 1;
                        
                    end //  if (bit_count == 1 ) begin
                                                        
                end // ST_READ_1X_DUMMY
                
                ST_READ_4X_DUMMY: begin
                
                    // This is the same as ST_READ_1X_DUMMY, except that when the count is done it will load 4 bits into io_ou[0:3] and then jump to state ST_SHIFT_TX4
                
                    if (bit_count == 1 ) begin
                    
                        // we test for 1 rather than 0 becuase we are on the rising edge of the clk, so cnt not updated yet
                    
                        // We are done reading the address bits, so start sending the data!
                                                
                        // TODO: THIS SHOULD BE MACRO
                        
                        // Preload the 4 bits
                        next_quad_out <=   DATA_PATTERN[ $high(DATA_PATTERN) -: 4 ];
                
                        // stuff the rest of the bits into the shift register                                                      
                        shift_out_x1[ $high(shift_out_x1) -: ($bits(DATA_PATTERN)-4) ] <= { DATA_PATTERN[ $high( DATA_PATTERN ) -4 : 0]  };
                        
                        // switch to sending mode. the posedge clk will see this state and enable output and send the nibbles
                        state <= ST_SHIFT_TX4;
                        output_enable_pos <= 1'b1;
                        tx_flag <= 1'b1;
                    
                                                
                    end else begin
                    
                        bit_count <= bit_count - 1;
                        
                    end //  if (bit_count == 1 ) begin
                    
                end // ST_READ_4X_DUMMY:
    
            endcase //  case (state)
                  
        end // els of if (qspi_cs)
            
    end // always_ff @(posedge qspi_clk, posedge qspi_cs) begin

    
    // LED on when we are active
    assign led = 1'b0;
    
    // gnd pin is always tied low for convienice
    assign gnd = 1'b0;
       
     
endmodule
