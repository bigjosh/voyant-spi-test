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

module top (
    // Quad-SPI pins 
    input  logic        qspi_clk,     // Serial clock from master (mode-agnostic)
    input  logic        qspi_cs,      // Chip-select, *active-LOW*
    inout  logic        qspi_dat0,    // IO0  - MOSI in 1-bit mode, bit-0 in x4
    inout  logic        qspi_dat1,    // IO1  - MISO in 1-bit mode, bit-1 in x4
    inout  logic        qspi_dat2,    // IO2  -             (unused in 1-bit)
    inout  logic        qspi_dat3,    // IO3  -             (unused in 1-bit)

    // Extras to make work easier
    output logic        gnd,          // Hard-wired ZERO - makes PCB nets happy
    output logic        led,          // Heart-beat LED (blinks on any read)
    output logic        debugA,       // On logic analyzer
    output logic        debugB        // On logic analyzer
    
);

        
    // This is sent to the master when it issues OPCODE_READ_ID
    // Taken from datasheet page 34 
    localparam [31:0] JEDEC_ID        = {    
        8'h20,   //  Manufacturer=Micron
        8'hBB,   //  Memory type=1.8V
        8'h17,   //  Capacity=16Mb = 8MB. This is small enough that the driver will only use 3-byte addressing, saving us a byte on each transaction. 
        8'h00    //  Num bytes remaing in this ID (non-standard, but works with spi-nor driver) 
    };
    
    // OP codes for the above chip (also from datasheet)    
    localparam [7:0]  OPCODE_READ_ID    = 8'h9F;          // Read 24 bit device ID block
    localparam [7:0]  OPCODE_READ       = 8'h03;          // Read with address (default 24 bit address)
    localparam [7:0]  OPCODE_QOFR       = 8'h6B;          // Quad Output Fast Read
              
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
//    localparam [63:0] DATA_PATTERN    = 64'hFFEEDDCC_BBAA9988;
    localparam [127:0] DATA_PATTERN    = 127'h00112233_44556677_8899AABB_CCDDEEFF;
    
    //localparam [191:0] DATA_PATTERN    = 192'h01234567_89ABCDEF_FEDCBA98_76543210_CAFEBABE_DEADBEEF;
    
    // Drive all 4 io pins? (Otherwise normal SPI so only drive dat1 = MISO) 
    logic quad_tx_mode = 1'b1;
    
    // Are we driving pins? Both of these need to be enabled for pins to be output.
    // This dance lets us send on the negedge of clk 
    logic output_enable_pos;
    logic output_enable_neg;
    
    // IO pins are assigned to tristate except for when CS is active and we are transmitting
    // if either one of those is not true, then pin is Hi-Z

    // in x1 mode, this is MOSI
    logic io0_out;
    assign qspi_dat0 = (output_enable_pos && output_enable_neg && !qspi_cs && quad_tx_mode ) ? io0_out : 1'bz;
    
    // in x1 mode this is MISO (an output)
    logic io1_out;
    assign qspi_dat1 = (output_enable_pos && output_enable_neg && !qspi_cs ) ? io1_out : 1'bz;

    logic io2_out;
    assign qspi_dat2 = (output_enable_pos && output_enable_neg && !qspi_cs && quad_tx_mode ) ? io2_out : 1'bz;

    logic io3_out;
    assign qspi_dat3 = (output_enable_pos && output_enable_neg && !qspi_cs && quad_tx_mode ) ? io3_out : 1'bz;

    // TODO: Take out 1bit read stuff? We needed it initially get things going. 
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
    
    // Be ready for 32 words, 32 bits each per packet. 
    //logic [ (32*32)-1 :0] shift_out;
    // TODO
    //logic [ 63 :0] shift_out = 64'hCAFEBABE_DEADBEEF;
    logic [ 1023 :0] shift_out ; //= 64'h11223344_55667788;
    
    
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
    assign debugA = (state == ST_READ_4X_DUMMY ) ? 1'b1 : 1'b0;
    assign debugB = (state == ST_SHIFT_TX4 ) ? 1'b1 : 1'b0;
    
    // When sending, we need to update our outputs on the negedge CLK so they will be ready for the master to sample on the posedge   
    // Note this depends on there being a negedge clk between transmit bursts, but luckily in SPI protocol there will always be a command
    // first followed by the transmit so OK.    
    always_ff @(negedge qspi_clk) begin
            
        if ( tx_flag ) begin
                
            output_enable_neg <= 1'b1;

            io0_out <= next_quad_out[0];
            io1_out <= next_quad_out[1];
            io2_out <= next_quad_out[2];
            io3_out <= next_quad_out[3];
                                      
        end else begin
        
            output_enable_neg <= 1'b0;
                        
        end         
    end
    
    // Define a combinational signal for to peek the next shift-in value since it is used multipule times below
    logic [$high(shift_in_x1) :0] shift_in_x1_next;
    assign shift_in_x1_next = {shift_in_x1[ ($high( shift_in_x1)-1):0], qspi_dat0};    
        
    logic posedge_cs_detected = 1'b1; 
    
    // Main logic            
    always_ff @(posedge qspi_clk or posedge qspi_cs) begin
    
        if ( qspi_cs ) begin
        
            posedge_cs_detected <= 1'b1;
            
        end else begin
        
            if (posedge_cs_detected) begin
            
                // Clear the flag for next time
                posedge_cs_detected <= 1'b0; 
                                     
                // We saw a rising CS since last posedge clk (or we powered up), so reset everything. 
                // Slightly complicated becuase we have a bit to ready rigght now. 
                        
                // CS high so we have been deselected. we need to reset everything and get red for next trasnaction.
                    
                // imedeately tri-state the oouts so other people can use the bus
                // better to put a `& ~qspi_cs` into the assign? 
                output_enable_pos <= 1'b0;
                
                tx_flag <= 1'b0;
                quad_tx_mode <= 1'b0; 
              
                state       <= ST_CMD_CAPTURE;      // Always reset to waiting for a command after CS deassertion.
                shift_in_x1 <= shift_in_x1_next;       // qspi_dat0 = MOSI in non-quad mode.
                bit_count   <= 1;
                
            end else begin                                                  
                     
                // CS is asserted and we are already actively doing stuff since the last negedge cs
            
                case (state)
    
                    ST_CMD_CAPTURE: begin
                    
                        // Note this is a blocking assignment 
                        //logic next_shift_in_x1 =  {shift_in_x1[6:0], io0_in};
        
                        if (bit_count == 7 ) begin     
                        
                            // We read 7 bits, so with this current one we have all 8!
    
                            unique case ( shift_in_x1_next ) 
                            
                                OPCODE_READ_ID:  begin
                                
                                    // This command is the master asking us for our ID, so we send it.                              
                                    
                                    // Preload the first bit. Dont care about the other dat pins we are in 1x mode now. ([1]=MISO) 
                                    next_quad_out[1] <= JEDEC_ID[ $high(JEDEC_ID) ];
                        
                                    // stuff the rest of the bits into the shift register
                                    shift_out[ $high(shift_out) -: ($bits(JEDEC_ID)-1) ] <= { JEDEC_ID[ $high( JEDEC_ID ) -1 : 0]  };
                                    
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
                                    bit_count <= (3*8) + (8) ;    // 3 address bytes + 8 dummy cycles. TODO: We can get rid of the dummies by implementing the capabilities table.                                                               
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
                            // qspi_dat0 = MOSI in non-quad mode
                                              
                            shift_in_x1 <= shift_in_x1_next;
                            bit_count   <= bit_count + 1;
                                             
                        end // if (bit_count == 3'd7) begin 
                        
                        
                    end // ST_CMD_CAPTURE
                    
                    
                    ST_SHIFT_TX1: begin
                    
                        // always send next bit. note the bit will actually be put out the pin on the posedge clk by an always block above.
                        // no count, will keep sending over and over again forever.
                        next_quad_out[1] <=   shift_out[ $high(shift_out) ];
                        shift_out <= shift_out << 1;
                        
                        
                    end
                                        
                    
                    ST_READ_1X_DUMMY: begin
                    
                        if (bit_count == 1 ) begin
                        
                            // we test for 1 rather than 0 becuase we are on the rising edge of the clk, so cnt not updated yet
                        
                            // We are done reading the address bits, so start sending the data!
                                                    
                            // TODO: THIS SHOULD BE MACRO
                            
                            // Preload the first bit
                            next_quad_out[0] <=   DATA_PATTERN[ $high(DATA_PATTERN) ];
                    
                            // stuff the rest of the bits into the shift register
                            // TODO                                                      
                            // shift_out[ $high(shift_out) -: ($bits(DATA_PATTERN)-1) ] <= { DATA_PATTERN[ $high( DATA_PATTERN ) -1 : 0]  };
                            
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
                            // TODO
                            next_quad_out <= DATA_PATTERN[ $high(DATA_PATTERN) -: 4 ];
                    
                            // stuff the rest of the bits into the shift register                                                      
                            shift_out[ $high(shift_out) -: ($bits(DATA_PATTERN)-4) ] <= { DATA_PATTERN[ $high( DATA_PATTERN ) - 4 : 0]  };
                            
                            // switch to sending mode. the posedge clk will see this state and enable output and send the nibbles
                            state <= ST_SHIFT_TX4;
                            output_enable_pos <= 1'b1;
                            tx_flag <= 1'b1;
                            quad_tx_mode <= 1'b1; 
                                                                            
                        end else begin
                        
                            bit_count <= bit_count - 1;
                            
                        end //  if (bit_count == 1 ) begin
                        
                    end // ST_READ_4X_DUMMY:
                    
                    ST_SHIFT_TX4: begin
                    
                        // always send next bit. note the bit will actually be put out the pin on the posedge clk by an always block above.
                        // no count, will keep sending over and over again forever.
//                      next_quad_out <=  shift_out[ $high(shift_out) -: 4 ];
                        
                        next_quad_out <=  shift_out[ $high(shift_out) -: 4  ];
                        
                        // TODO: For now we stuff magic 0101 in so we cna see it come out, but probably better to use 00?
                        //shift_out  <= { shift_out[ ($high(shift_out) - 4 ) : 0  ] , 4'b1010 } ;
                        
                        shift_out <= shift_out << 4;                                                                    
                        
                    end  // ST_SHIFT_TX4: 
                            
                endcase //  case (state)
                      
            end // if (posedge_cs_detected)
        end // if ( qspi_cs ) begin                        
    end // always_ff @(posedge qspi_clk, posedge qspi_cs) begin

    
    // LED on when we are active
    assign led = 1'b0;
    
    // gnd pin is always tied low for convienice
    assign gnd = 1'b0;
       
     
endmodule
