// Send test data as fast as the master can clock it out!
// Currently CS active LOW 

module top #(
    // These must match the receiver code
    parameter int BITS_PER_WORD       = 32,             // Sorry, i get confused - there are so many kinds of words in this world!
    parameter int WORDS_PER_PAYLOAD   = 23              
) (
    input  logic        multi_spi_clk,   // SPI clock from master
    input  logic        multi_spi_cs,    // Active-LOW CS
    output logic        multi_spi_miso,   // Master-in-slave-out
    output logic        gnd,
    output logic        led
);

    typedef logic [BITS_PER_WORD-1:0] u32_t;          // 4-state, unsigned

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


    shift_reg_t shift_reg;
    
    localparam int SHIFT_REG_LEN = $bits(shift_reg);  
    
    // I was tempted to put a sentinal bit at the end instead of a counter, but that ends up using more LUTs becuase you need to spead the compare on all the shift counter bits across a tree.
    // Mayb there is some way to do a chain or OR gates with each one taking one bit of the shift_reg one one input and the output of the previous OR gate on the other? Is that better? 
    logic [$clog2(SHIFT_REG_LEN)-1:0]  shift_count = '0;    // Count this bits going out (size the reg just big enough)
                                                            // INit to 0 so we start up right in case we power up with CS already active.  
        
           
    
    always_ff @(posedge multi_spi_clk or posedge multi_spi_cs) begin
    
        // This will happen on every clk while CS is inactive, but that is OK   
        // Note that we must init count and seq to these values so everything works
        // on the first negedge CS after powerup. 
         
        if (multi_spi_cs) begin                  // asynchronous
    
            // Negedge on cs signal end of transaction
            // we rerset everything so we will be ready for start of next transaction which we will 
            // only know when it starts with the first posedge clk
                
            shift_count <= '0;                   // force "need reload"
            packet_seq  <= 32'd1;                // restart at 1
            
        end else begin 
        
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

    //------------------------------------------------------------------
    // Drive the MISO pin (tri-state when not selected)
    //------------------------------------------------------------------
    //assign multi_spi_miso = (multi_spi_cs) ? shreg[31] : 1'bz;
    assign multi_spi_miso = shift_reg[$high(shift_reg)];
    
    // TODO: tristate the MISO when !CS

    assign led = ~multi_spi_cs;     
    assign gnd = 1'b0;
    
endmodule
