// -----------------------------------------------------------------------------
// spi_slave.sv - packet-builder factored into a single function
// TODO: Make a way to leave MISO high until data is Ready for synchonization 
// -----------------------------------------------------------------------------


module spi_slave #(
    parameter int BITS_PER_WORD       = 32,             // Sorry, i get confused - there are so many kinds of words in this world!
    parameter int WORDS_PER_PAYLOAD   = 31,             // 34 data words (does not include CRC which will be appended to the packet)
    parameter int ECSPI_BUFFER_DEPTH  = 36             // This is from the i.MX8MP reference. As long as we send less than this, we should not have to worry 
                                                       // about overflows on the CPU side. 
    
) (
    input  wire        multi_spi_clk,
    input  wire        multi_spi_cs,                 // active-HIGH
    inout  wire        multi_spi_miso,               // Hi-Z when CS==0
    output wire        gnd,
    output wire        led
);


    typedef logic [BITS_PER_WORD-1:0] u32_t;          // 4-state, unsigned

    // A payload is the useful data in a packet, does not include the CRC that will be appened before transmision.
    // Note that the major index starts at 0, so index 0 will be MSB and go out the wire first.
    typedef logic [0:WORDS_PER_PAYLOAD-1][BITS_PER_WORD-1:0] payload_t;    

  
    u32_t next_packet_seq  = 32'd0;       // A running global packet sequnece number just to keep things changing.
                                          // Rolls every 4 billion or so, but that should be long enough to detect dropped packets
    
    localparam [31:0] MAGIC_COOKIE = "LiDR";        // 0x4c694452

    // -----------------------------------------------------------------------------
    // This is just an example that geneates some interesting test data 
    // -----------------------------------------------------------------------------
    function automatic payload_t
        build_payload (input u32_t seq);
        payload_t payload = '0;
        
        // Note the we declared payload_t specifically so that index 0 is MSB and will go out the wire firstly.
                        
        int i = 0;
        
        // Start with a magic cookie        
        payload[i++] = MAGIC_COOKIE;
        
        // Next our sequence number
        payload[i++] = seq;
        
        // And fill the rest with some test data.
        
        while (i<WORDS_PER_PAYLOAD) begin
        
            payload[i] = { "Vyt", i[7:0]};          // 0x567974ii
            i++;
            
        end 
        
        return payload;
    endfunction
    
    // -------------------------------------------------------------------------
    // Synthesizable CRC-32 (big-endian, IEEE 802.3)
    // -------------------------------------------------------------------------
    function automatic u32_t crc32 (payload_t d);
        u32_t crc = 32'hFFFF_FFFF;
        for (int i = $bits(d)-1; i >= 0; i--) begin
            logic fb = d[i] ^ crc[31];
            crc      = {crc[30:0], fb};
            if (fb)  crc ^= 32'h04C11DB7;
        end
        return ~crc;
    endfunction
    
    typedef struct packed {
        payload_t payload;
        u32_t     crc;          // This is the last thing to get shifted out becuase our SPI is MSB first.            
    } packet_t;
    
    
    // -----------------------------------------------------------------------------
    // Turns a payload_t into a packet_t by adding a 32-bit CRC to the end 
    // -----------------------------------------------------------------------------
    function automatic packet_t
        build_packet (payload_t payload);
        
        packet_t packet = '0; 
        
        packet.payload = payload;
        packet.crc = crc32( payload );
        
        return packet;
        
     endfunction
             
      
    localparam int MAX_ECSPI_PACKET_SIZE_BITS = ECSPI_BUFFER_DEPTH * BITS_PER_WORD;  
        
    // This is what actually gets shifted out the MISO on each CLK edge
    // We initialize with some easy to eyeball data for debugging. This is what you'll see
    // on a logic analyzer if you reset the FPGA with CS already high and start clocking out bits
    // (should never happen in real life)  
        
    packet_t shift_reg = '{
        crc  : 32'h01020304,
        payload : '{ default : 32'h0,             // zero everything …
                    1        : 32'hFFFF_FFFF,     // … then override a few words
                    3        : 32'h5555_5555,
                    4        : 32'hAAAA_AAAA
                  }
    };    
    
    
    initial begin
        assert ($bits(shift_reg) <= MAX_ECSPI_PACKET_SIZE_BITS )
        else $error("shift_reg is %0d bits (%0d words) - exceeds %0d-word buffer size on the recieving ECSPI device",
                    $bits(shift_reg),
                    $bits(shift_reg)/BITS_PER_WORD,
                    ECSPI_BUFFER_DEPTH);
    end
    
    
    
    // Out level of the MISO pin when CS is Active
    logic miso_out = 1'b0;
    
    //always_ff @(posedge multi_spi_cs)
    //  miso_out <= 1'b0;

    // ---------------------------------------------------------------------
    // Edge detector (one-cycle pulse on CS rising edge)
    // ---------------------------------------------------------------------
    logic cs_d = 1'b1;  // Start with this high so we do not find an edge if we power up with CS high
    
    always_ff @(posedge multi_spi_clk or negedge multi_spi_cs) begin
        if (!multi_spi_cs)        // asynchronous clear whenever CS drops
            cs_d <= 1'b0;
        else                      // normal update on the clock edge
            cs_d <= 1'b1;         // (or cs_d <=  multi_spi_cs; either works)
    end    
    
    wire cs_rise = multi_spi_cs & ~cs_d;  // now guaranteed 1-cycle pulse
    
    // ---------------------------------------------------------------------
    // Load-or-shift
    // ---------------------------------------------------------------------
    always_ff @(posedge multi_spi_clk) begin
    
        if (cs_rise) begin
    
            // new rising CS edge since the last clk rising edge 
            // load a BRAND-NEW packet
            
            /*
            static packet_t new_packet  = '{
                header  : 32'hFFEEDDCC,
                payload : '{ default : 32'h0,
                             1 : 32'hFFFF_FFFF,
                             3 : 32'hCAFE_BABE,
                             4 : 32'hDEAD_BABE,
                             5 : packet_seq
                           }
            };
            
            */
                        
            static packet_t new_packet = build_packet( build_payload( next_packet_seq ) );

            miso_out  <= new_packet[$high(new_packet)]; // new packet's MSB
            shift_reg <= new_packet << 1;
           
            // Update sequnce number for next packet;              
            next_packet_seq <= next_packet_seq + 1;
        end
        else begin      
            miso_out  <= shift_reg[$high(shift_reg)];
            shift_reg <= shift_reg << 1;                    
        end
    end
                
    // -------------------------------------------------------------------------
    //  Tri-state MISO when CS low
    // -------------------------------------------------------------------------
    
    assign multi_spi_miso = multi_spi_cs ? miso_out : 1'bz;

    // -------------------------------------------------------------------------
    //  Misc. Connections
    // -------------------------------------------------------------------------
    
    // Some visual feedback? Too dim at 1.8V and I can't figure out how to make just that one pin be 3.3V. Can you, gentle reader?
    assign led = multi_spi_cs;

    // This generates a warning that I do not know how to fix?    
    assign gnd = 1'b0;
    
endmodule
