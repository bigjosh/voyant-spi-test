
// -----------------------------------------------------------------------------
// -----------------------------------------------------------------------------
//  SPI-slave with 1 120-bit payload (35 × 32-bit words)             Avery Levine
//  - MISO goes Hi-Z whenever multi_spi_cs == 0 (slave not selected)
//  - When selected (multi_spi_cs == 1) one bit is shifted out each CLK edge
// -----------------------------------------------------------------------------
//
//  ▀▀▀ Compile-time parameters - change these to suit your own packet size
//
localparam integer BITS_PER_WORD       = 32;      // do NOT use "parameter" here
localparam integer WORDS_PER_PAYLOAD   = 35;      // 35-word packet
localparam integer BITS_PER_PAYLOAD    = BITS_PER_WORD * WORDS_PER_PAYLOAD;

//  How many counter bits do we need to count from (BITS_PER_PAYLOAD-1 → 0) ?
localparam integer CNT_WIDTH = $clog2(BITS_PER_PAYLOAD);

// -----------------------------------------------------------------------------
//  Top-level port list
//
module spi_hiz_test(

    input  wire        multi_spi_clk,   // SPI clock from the master
    input  wire        multi_spi_cs,    // ACTIVE-HIGH chip-select
    inout  wire        multi_spi_miso,  // becomes Hi-Z whenever CS==0
    output wire        gnd,             // handy tie-low pin near the other pins  
    
    output wire        led              // Debuging LED on TE0703 carrier board
);

//reg  [1:0] led_flop = 1'b0;
assign gnd            = 1'b0;                  // spare ground pin
    
// -----------------------------------------------------------------------------
//  ▀▀▀ Demo payload generator
//      * Each of the 35 words is 0xF0F0 | word_index[15:0] so you can see
//        corruption easily on a logic-analyser.
//      * Feel free to replace this with real data from a FIFO, BRAM, etc.
// -----------------------------------------------------------------------------
reg  [BITS_PER_PAYLOAD-1:0]  shift_reg   = '0;          // Holds the packet bits
reg  [CNT_WIDTH-1:0]         bit_cnt     = '0;          // Counts down 1119→0

// A second register just so we can increment the test pattern each packet
reg  [15:0]                  packet_index = 16'd0;

// -----------------------------------------------------------------------------
//  ▀▀▀  Load-and-shift logic
// -----------------------------------------------------------------------------
integer i;
always @(posedge multi_spi_clk or negedge multi_spi_cs) begin
    // -------------------------------------------------------------------------
    //  ❶  CS goes LOW  →  reload the shift register with a fresh payload
    // -------------------------------------------------------------------------
    if (!multi_spi_cs) begin
        //  Build a new 1 120-bit packet **************************************
        for (i = 0; i < WORDS_PER_PAYLOAD; i = i + 1) begin
            // [bit 1119] … [bit 0]  (MSB first)
            // Stuff: { 0xF0F0, packet_index, word_index }
            shift_reg[ BITS_PER_PAYLOAD-1 - i*BITS_PER_WORD -: BITS_PER_WORD ]
                 <= { 16'hF0F0, packet_index, i[3:0] };   // 32-bit word
        end
        packet_index <= packet_index + 1'b1;   // Different pattern next time

        bit_cnt <= BITS_PER_PAYLOAD-1;         // Start shifting from MSB
    end
    // -------------------------------------------------------------------------
    //  ❷  CS is HIGH  →  shift one bit every rising CLK edge
    // -------------------------------------------------------------------------
    else begin
        // When the last bit goes out we simply wrap: the pattern will repeat
        if (bit_cnt == 0) begin
            bit_cnt   <= BITS_PER_PAYLOAD-1;
        end else begin
            bit_cnt   <= bit_cnt - 1'b1;
        end

        //  Shift MSB-first: every edge throws away the current MSB
        shift_reg <= { shift_reg[BITS_PER_PAYLOAD-2:0], 1'b0 };
    end
end

// -----------------------------------------------------------------------------
//  ▀▀▀ Tri-state buffer
//      - Drives the current MSB while CS==1
//      - Releases the pin (Hi-Z) while CS==0
// -----------------------------------------------------------------------------
wire miso_data = shift_reg[BITS_PER_PAYLOAD-1];
assign multi_spi_miso = (multi_spi_cs) ? miso_data : 1'bz;

endmodule