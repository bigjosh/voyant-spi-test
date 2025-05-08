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

         
    typedef logic [ 31:0 ] u32_t;
   
    parameter int BITS_PER_WORD        = 32;
    parameter int WORDS_PER_PACKET     = 32;
    
    // This is Wierd. We put word index 0 first so it going out the wire first, but we put bit index 0 last so all numbers are MSB first. 
    typedef logic [ 0 : WORDS_PER_PACKET-1 ][BITS_PER_WORD-1:0]  packet_t  ;                                   
        
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
    
    // Drive all 4 io pins? (Otherwise normal SPI so only drive dat1 = MISO) 
    logic quad_tx_mode = 1'b1;
    
    // Are we driving pins? Both of these need to be enabled for pins to be output.
    // This dance lets us send on the negedge of clk 
    logic output_enable_neg;
    


    // TODO: Take out 1bit read stuff? We needed it initially get things going. 
    typedef enum logic [2:0] {
        ST_CMD_CAPTURE   = 3'd1,   // Shifting in 8-bit op-code (this is default idle state)
        ST_SHIFT_TX1     = 3'd2,   // Shifting out what ever is in shift_out_x4 on dat1 forever
        ST_SHIFT_TX4     = 3'd3,   // Shifting out what ever is in shift_out_x4 on dat[0:3] forever                        
        ST_READ_4X_DUMMY = 3'd5,   // Discard how ever many clocks are in bit_count then go to ST_SHIFT_TX4 (used for consuming address & dummy bits on read)
        ST_DEAD          = 3'd7    // Do nothing, wait for a CS reset 
    } state_t;

    state_t state = ST_CMD_CAPTURE;
    
    
    
    // Easy to eyeball test data
    localparam [ 127 :0] DATA_PATTERN    = 128'h01234567_89ABCDEF_FFFFFFFF_00000000;
                   
    // Whatever is in here goes out the door when in ST_shift_out_x4
           
    logic [ 63 :0] shift_out_x4 =  64'h01234567_89ABCDEF;  //DATA_PATTERN[ 127 : 64] ; 
    
    // A define becuase I don't think a task or function can take
    // I know this is ugly, but I don't know a better way to pass a (compile-time) variable len packed array. Do you? 
    
        
    // Incoming command byte
    logic [7:0] shift_in_x1 ;
    
    // Need to send 4 bytes in single MISO to answer 9F device ID
    logic [$high(JEDEC_ID):0] shift_out_x1;     
        
    // a bit_counter, means didfferent things in different states
    // In ST_CMD_CAPTURE: This is number of command bits in shift_in_x1 so far (<8)  
    // In ST_READ_Xx_DUMMY: This is the number of dummy bits to read before switching to READ state 
    logic [7:0] bit_count = 0;         // How many bits in shift so far?
        
    // Written to by posedge clk, read by negedge clk
    // we need this becuase the master reads on the posedge
    //logic [3:0] next_quad_out;
    
    // Are we currently transmitting?
    // This just makes it so we don't need to keep track of which states are transmit states here. Better to know that 
    // close to where those states are enetered. 
    // used in posedge clk to output next bits (also enables the outputs if they are not alreday enabled)
    logic tx_flag =1'b0;
    
    //    assign debugA = qspi_clk;
    assign debugA = (state == ST_READ_4X_DUMMY ) ? 1'b1 : 1'b0;
    assign debugB = (state == ST_SHIFT_TX4 ) ? 1'b1 : 1'b0;
    
    
    // Assign the data outputs to the top of the apropriate shift reg based on if we are in quad or single bit mode
    assign  io3_val = shift_out_x4[ $high( shift_out_x4 ) - 0 ];
    assign  io2_val = shift_out_x4[ $high( shift_out_x4 ) - 1 ];
    assign  io1_val = ( quad_tx_mode ) ? shift_out_x4[ $high( shift_out_x4 ) - 2 ] : shift_out_x1[ $high( shift_out_x1) ];   // This pin is also MISO when in single bit mode  
    assign  io0_val = shift_out_x4[ $high( shift_out_x4 ) - 3 ];
    
    logic io3_out;
    logic io2_out;
    logic io1_out;  
    logic io0_out;

    
    // IO pins are assigned to tristate except for when CS is active and we are transmitting
    // if either one of those is not true, then pin is Hi-Z

    // in x1 mode, this is MOSI
    assign qspi_dat0 = (tx_flag && output_enable_neg && !qspi_cs && quad_tx_mode ) ? io0_out : 1'bz;
    
    // in x1 mode this is MISO (an output)
    assign qspi_dat1 = (tx_flag && output_enable_neg && !qspi_cs ) ? io1_out : 1'bz;

    assign qspi_dat2 = (tx_flag && output_enable_neg && !qspi_cs && quad_tx_mode ) ? io2_out : 1'bz;

    assign qspi_dat3 = (tx_flag && output_enable_neg && !qspi_cs && quad_tx_mode ) ? io3_out : 1'bz;    
        
    // When sending, we need to update our outputs on the negedge CLK so they will be ready for the master to sample on the posedge   
    // Note this depends on there being a negedge clk between transmit bursts, but luckily in SPI protocol there will always be a command
    // first followed by the transmit so OK.    
    always_ff @(negedge qspi_clk) begin
            
        if ( tx_flag ) begin
        
            // grab the current bit values from the shift reg and put them out on the pins
            io0_out <= io0_val;
            io1_out <= io1_val;
            io2_out <= io2_val;
            io3_out <= io3_val;
        
            output_enable_neg <= 1'b1;
                                                               
        end else begin
        
            output_enable_neg <= 1'b0;
                        
        end         
    end
    
    // Define a combinational signal for to peek the next shift-in value since it is used multipule times below
    logic [$high(shift_in_x1) :0] shift_in_x1_next;
    assign shift_in_x1_next = {shift_in_x1[ ($high( shift_in_x1)-1):0], qspi_dat0};
        
    logic posedge_cs_detected = 1'b1; 
    
    // Give each packet a 4-bit serial number at the begining. 
    logic [3:0] seq = 0;
    
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
                                                            
                                    // The top bit of the shift reg will appear on MISO on the next negedge spi_clk
                                    shift_out_x1 <= JEDEC_ID;
                                    
                                    // switch to sending mode. We will send this bit and enable the outputs on next negedge clk
                                    state <= ST_SHIFT_TX1;
                                    tx_flag <= 1'b1;
                                                                                                                
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
                        // no count, will keep sending over and over again forever. We depend on the host to only ready how much it needs
                        shift_out_x1 <= shift_out_x1 << 1;
                        
                        
                    end
                                        
                    
                    ST_READ_4X_DUMMY: begin
                                        
                        if (bit_count == 1 ) begin
                        
                            // We (almost) finished reading the dummy bits (we also consider address bits to be dummy since we don't care)                        
                            // we test for 1 rather than 0 becuase we are on the rising edge of the clk, so cnt not updated yet
                        
                            // Start sending the data!                                                                               

                            // First Nibble will be a 4-bit sequence number so host can detect any missed packets.
                            
                            //warning debug code
                            // Note for now we are preloading the x4 shift register and rotating though. 
                            //shift_out_x4[ $top(shift_out_x4) -: $bits(DATA_PATTERN) ] <= DATA_PATTERN;                                  
                                    
//                            next_quad_out <= seq[3:0];
//                            seq <= seq+1;                                  
                                                
                            // switch to sending mode. the posedge clk will see this state and enable output and send the nibbles
                            state <= ST_SHIFT_TX4;
                            tx_flag <= 1'b1;
                            quad_tx_mode <= 1'b1;
                                                                            
                        end else begin
                        
                            bit_count <= bit_count - 1;
                            
                        end //  if (bit_count == 1 ) begin
                        
                    end // ST_READ_4X_DUMMY:
                    
                    ST_SHIFT_TX4: begin
                    
                        // no count, will keep rotating shift and sending over and over again forever.
                        shift_out_x4 <= { shift_out_x4[ $high(shift_out_x4)-4 : 0 ] , shift_out_x4[ $high(shift_out_x4) -: 4  ] };                         
                    
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
