// Send test data as fast as the master can clock it out!
// Currently CS active LOW 

module top #(
    // These must match the receiver code
    parameter int BITS_PER_WORD       = 32,             // Sorry, i get confused - there are so many kinds of words in this world!
    parameter int BITS_PER_BYTE       = 8,
    parameter int WORDS_PER_PAYLOAD   = 23              
) (
    input  logic        multi_spi_clk,   // SPI clock from master
    input  logic        multi_spi_cs,    // Active-LOW CS
    inout  logic        multi_spi_miso,   // Master-in-slave-out. inout becuase we tristate it when CS not active
    inout  logic        multi_spi_mosi,
    output logic        gnd,
    output logic        led
);

    assign qspi_cs  = multi_spi_cs;
    assign qspi_clk = multi_spi_clk;
    assign qspi_d0  = multi_spi_mosi;
    assign qspi_d1  = multi_spi_miso;

    typedef logic [BITS_PER_WORD-1:0] u32_t;          // 4-byte, unsigned
    typedef logic [BITS_PER_BYTE-1:0] u8_t;           // a byte

    // A payload is the useful data in a packet, does not include the CRC that will be appened before transmision.
    // Note that the major index starts at 0, so index 0 will be MSB and go out the wire first.
    typedef logic [0:WORDS_PER_PAYLOAD-1][BITS_PER_WORD-1:0] payload_t;
    
    // Easy to eyeball stuff. 
    payload_t test_payload = '{
    
        default : 32'hDEAD_BEEF,      // fill any trailing words with dead_beef        
        0       : 32'hABCD_EF00,      // override element 
        1       : 32'h9876_5432,      // override element 
        2       : 32'h2468_2468,       // override element 
        3       : 32'h5555_5555,      // override element 
        4       : 32'hAAAA_AAAA,      // override element 
        5       : 32'hFFFF_FFFF,      // override element
        6       : 32'h0000_0000,       // override element
        7       : 32'h0000_0001,      // override element
        8       : 32'h0000_0000,       // override element                
        9       : 32'hFFFF_FFFF,       // override element
       10       : 32'hFFFF_FFFE,      // override element
       11       : 32'hFFFF_FFFF,       // override element                
       12       : 32'h1234_ABCD       // override element                              
    };        

    u32_t packet_seq = 32'd1 ;        // starts at 1 when CS goes active, but init here just in case we pwoer up with CS already active 
                                     // should overflow to 1, but should never be a single trasnaction that long.                    
    typedef struct packed {
        u32_t seq;
        payload_t payload;
    } packet_t;
    
    // shift register holds a full packet plus one extra bit at the top
    //abstract it here, maybe someday we want to make the shift reg be more stuff?
    typedef struct packed {
        packet_t packet;
    } shift_reg_t;
       
            
    /*
    
        I need to walk though the counter semantics....
        
        Let say shift reg len is 3 bits. ABC. so len is 3.
        
        When CS first goes active, count=0
        
        Then the posedge CLK happens, sees count==0 so loads shift register ABC and sets count = len-1 = 2. MSB is on MISO
        
        2nd pos edge CLK. shift now BC, count =1 
        
        3rd pos edge clk, shift C , count 0. MISO is C
        
        4th posedge clk, count ==0 so reload to above
        
        checks out!  
    
    */


    // Outbound shift reg, must be big enough to hold a packet
    shift_reg_t shift_reg;
/*    
    // 
    task automatic put_shift_reg (input logic[*] src);   // open packed array
      if (src.size() > shift_reg.size())
         $fatal(0, "src (%0d) wider than dest (%0d)",
                   src.size(), shift_reg.size());
    
      shift_reg[shift_reg.high() -: src.size()] = src;      // variable part-select
    endtask
    // ────────────────────────────────────────────────────────────────────
        
*/    
    // Inbound shift register, must be big enough to hold a command byte
    u8_t in_shift_reg;  
    
    
   typedef enum logic [2:0] { 
        STATE_RX_CMD ,              // Reading the device id command from the master. We reset to this state. bit_count is number of bits left -1 to read before we are done.  
        STATE_TX_CMD_RESPONSE      // Transmitting the response to a command to the master.  bit_count is number of bits left -1 to read before we are done.
    } state_t;
    
    
    state_t state      = STATE_RX_CMD;                // Reset to ready to read ID CMD    
    
    // We must specifically enable the transmitter on DAT0 becuase when we first start up this is used for full duplex 
    logic dat0_tx_enabled = 1;
    
    localparam int SHIFT_REG_LEN      = $bits(shift_reg);
    localparam int SHIFT_REG_HIGH_BIT = $high(shift_reg);
        
    /*
    if ($bits(shift_reg)>SHIFT_REG_LEN)
        $error($sformatf("Shift reg mus be long enough to hold a command byte"));
    endmodule
    */
    
           
    // I was tempted to put a sentinal bit at the end instead of a counter, but that ends up using more LUTs becuase you need to spead the compare on all the shift counter bits across a tree.
    // Mayb there is some way to do a chain or OR gates with each one taking one bit of the shift_reg one one input and the output of the previous OR gate on the other? Is that better? 
    logic [$clog2(SHIFT_REG_LEN)-1:0]  bit_count = '0;    // Count this bits going out (size the reg just big enough)
                                                            // Init to 0 so we start up right in case we power up with CS already active.                      
    always_ff @(posedge multi_spi_clk or posedge multi_spi_cs) begin
    
        // This will happen on every clk while CS is inactive, but that is OK   
        // Note that we must init count and seq to these values so everything works
        // on the first negedge CS after powerup. 
         
        if (multi_spi_cs) begin                  // asynchronous
        
            // ***** RESET ON ANY CS HIGH (not active)
    
            // Negedge on cs signal end of transaction
            // we rerset everything so we will be ready for start of next transaction which we will 
            // only know when it starts with the first posedge clk
               
            state =  STATE_RX_CMD;       // Ready to recieve a command 
            bit_count <= 8-1;             // force start reading first bit of 8 bits of command byte. Remeber that we will stop on the last bit, so -1
            dat0_tx_enabled <= 0;         // Do not transmit yet.
            
                        
        end else begin
        
            // *******   NORAML STATE MACHINE HERE - CS IS ACTIVE
            // If we get here, CS is active and clock just went high
            
            case (state) 
            
                STATE_RX_CMD: begin
                
                    // Recieving a command byte 
                                        
                    if (bit_count == 0 ) begin
                                                            
                        // We are now on the final bit of the command
                        
                        // The last incoming bit of the command is on miso now, so we grab already shifted in bits plus the immedeate value
                        case ({ in_shift_reg[6:0] , multi_spi_miso } ) 
                        
                            8'h9f: begin            // Read ID command
                            
                                // Send our response, which is our chip ID. 
                            
                                shift_reg[ SHIFT_REG_HIGH_BIT : SHIFT_REG_HIGH_BIT - ( BITS_PER_BYTE * 3 )  ]  =  {  8'h20 , 8'hbb , 8'hx22 };
                                bit_count = (8*3)-1; 
                                dat0_tx_enabled = 1'b0;
                                state = STATE_TX_CMD_RESPONSE;
                            
                            end               
                                                    
                        endcase
                        
                        */
                    
                    end else begin
                    
                        // We are currently in the middle of shifting in a command
                        
                        in_shift_reg <= { in_shift_reg[6:0] , multi_spi_miso } ;
                        
                        bit_count <= bit_count -1 ;
                        
                    end                                                
                        
                end // STATE_RX_CMD
                
                
                STATE_TX_CMD_RESPONSE: begin
                
                    if ( bit_count == 0 ) begin
                    
                        // Done shifting out our response
                        
                        state =  STATE_RX_CMD;       // Ready to recieve a command 
                        bit_count <= 7 ;             // force start reading first bit of 8 bits of command byte
                        dat0_tx_enabled = 0;         // Do not transmit yet.
                        
                    end else begin
                    
                        // We are currently in the middle of shifting out the response to a command
                        
                        in_shift_reg <= in_shift_reg << 1;                        
                        bit_count <= bit_count -1 ;                    
                    
                    end                        
                                                                   
                end // STATE_TX_CMD_RESPONSE
                
            endcase // state machine         
                    
        end // CS active
    end //  always on cs and clk               
         
                            
/*            
            endcase
        
            if (shift_count == 0) begin
    
                // Load a packet of data up. MISO will get the MSB so will be ready for the negedge clk
                shift_reg <= '{
                    packet: '{
                        seq: packet_seq,
                        payload: test_payload
                    }
                };
                
                packet_seq <= packet_seq + 1;
                
                // First bit is alread on MISO, so clock out len-1 more.                                 
                shift_count <= SHIFT_REG_LEN-1; 
                
            end else begin
           
                // CS is active and clock just rose so shift one bit
                shift_reg <= shift_reg << 1;
                shift_count <= shift_count - 1;
                
            end
        end 
    end
*/
    // The top bit of the shift reg goes out the door 
    //assign miso_out_bit = shift_reg[$high(shift_reg)];
    
    assign miso_out_bit = 1'b1;//shift_reg[$high(shift_reg)];
    
     
    // Tri-state the MISO pin if CS OR we are not transmitting right now. Otherwise miso_out on the pin. 
    // This is so we do not fight with either others on the bus or the master talking to us
    assign multi_spi_miso = (multi_spi_cs || !dat0_tx_enabled) ? 1'bz:   miso_out_bit   ;    


    //assign multi_spi_miso = multi_spi_clk ; //(multi_spi_cs || !dat0_tx_enabled) ? 1'bz:   miso_out_bit   ;
    // CLK pin good.    


    // assign multi_spi_miso = multi_spi_mosi ; //(multi_spi_cs || !dat0_tx_enabled) ? 1'bz:   miso_out_bit   ;
    // MOSI pin good    

    // assign multi_spi_miso = ~multi_spi_cs ; //(multi_spi_cs || !dat0_tx_enabled) ? 1'bz:   miso_out_bit   ;
    // CS pin good    


    assign led = ~multi_spi_cs;  
    
    // Convient connection point near the other pins on te carrier PCB.    
    assign gnd = 1'b0;
    
endmodule
