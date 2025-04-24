// -----------------------------------------------------------------------------
// One-packet-per-CS SPI-slave test streamer for Artix-7 @ 40 MHz
// Packet: 35 × 32-bit words (see comments below)
// CS is active-HIGH; a rising edge loads a new packet, one only.
// MISO shifts MSB-first on every rising edge of multi_spi_clk.
// -----------------------------------------------------------------------------
module top
(
    input  wire multi_spi_clk,   // 40 MHz external SPI clock (no BUFG)
    input  wire multi_spi_cs,    // chip-select, ACTIVE-HIGH
    output wire multi_spi_miso,  // data out, valid on clk rising edge

    output reg  led = 1'b0,      // toggles each new packet for scope/probe
    output wire gnd              // handy tie-low pin
);

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------
    localparam WORD_WIDTH        = 32;
    localparam WORDS_PER_PACKET  = 35;          // 0-to-34
    localparam RAMP_MAX          = 16'd4095;
    localparam LINE_MAX          = 2'd3;

    // Constant test data for the 8×peak_data blocks
    localparam [31:0] FREQ_BIN   = 32'h0000_0080;
    localparam [31:0] AMP_PREV   = 32'h0000_0022;
    localparam [31:0] AMP_PEAK   = 32'h0000_0033;
    localparam [31:0] AMP_NEXT   = 32'h0000_0044;
    localparam [31:0] CRC_DUMMY  = 32'h0000_0000;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------
    reg  [WORD_WIDTH-1:0] shreg      = {WORD_WIDTH{1'b0}};  // shift register
    reg  [4:0]            bit_cnt    = 5'd0;                // 31-0
    reg  [5:0]            word_cnt   = 6'd0;                // 0-34

    reg  [31:0]           timestamp  = 32'd0;               // free-running
    reg  [15:0]           ramp_cnt   = 16'd0;
    reg  [15:0]           line_cnt   = 16'd0;

    // Snapshots taken at CS rising-edge so the packet is internally consistent
    reg  [31:0]           ts_snap;
    reg  [15:0]           ramp_snap;
    reg  [15:0]           line_snap;

    reg                   cs_prev         = 1'b0;
    reg                   transfer_active = 1'b0;
    
    
    reg [1:0] miso_flop = 1'b0;   
    assign multi_spi_miso = miso_flop;   // MSB first
    
    // reg miso_flop = 1'b0;                       // Testing only
    // assign multi_spi_miso = miso_flop ;         // Test only      
    
    assign gnd            = 1'b0;                  // spare ground pin

    // -------------------------------------------------------------------------
    // Packet-word generator (uses snapshots)
    // -------------------------------------------------------------------------
    function [31:0] packet_word;
        input [5:0] idx;       // 0-34
        begin
            case (idx)
                6'd0  : packet_word = ts_snap;
                6'd1  : packet_word = {ramp_snap, line_snap};
                6'd34 : packet_word = CRC_DUMMY;

                default: begin
                    // words 2-33 : eight identical 4-word blocks
                    case (idx[1:0])            // idx mod 4
                        2'b10: packet_word = FREQ_BIN;  // 2,6,10,...
                        2'b11: packet_word = AMP_PREV;  // 3,7,11,...
                        2'b00: packet_word = AMP_PEAK;  // 4,8,12,...
                        2'b01: packet_word = AMP_NEXT;  // 5,9,13,...
                        default: packet_word = 32'hDEAD_BEEF; // should never hit
                    endcase
                end
            endcase
        end
    endfunction
    
    // Here we need to a negedge on CS to Hi-Z the MISO pin

    // -------------------------------------------------------------------------
    // Main process - everything in the incoming SPI clock domain
    // -------------------------------------------------------------------------
    
    // NOte here that we also have sensitivity to the falling edge of the chipselect,
    // this is so we have hi-Z the MISO pin immedeately and not need to wait for the next 
    // clock transition. 
    
    always @(posedge multi_spi_clk or negedge multi_spi_cs) begin
    
        if (!multi_spi_cs) begin
        
            miso_flop <= 1'b0;
        
        end
        
        cs_prev <= multi_spi_cs;    // edge detector
        
        // --------------------------------------------------------------
        //  CS LOW→HIGH : start a fresh one-packet transfer
        // --------------------------------------------------------------
        if (!cs_prev && multi_spi_cs) begin
            // snapshot the counters so the whole packet matches
            ts_snap   <= timestamp;
            ramp_snap <= ramp_cnt;
            line_snap <= line_cnt;

            // preload first word
            shreg      <= ts_snap;
            bit_cnt    <= 5'd31;
            word_cnt   <= 6'd0;
            transfer_active <= 1'b1;

            led        <= ~led;             // blink once per packet
            timestamp  <= timestamp + 32'd1; // keep counting
        end

        // --------------------------------------------------------------
        //  Active transfer: shift out exactly 35 words then stop
        // --------------------------------------------------------------
        else if (transfer_active && multi_spi_cs) begin
            shreg <= {shreg[WORD_WIDTH-2:0], 1'b0}; // shift left (MSB out)

            if (bit_cnt == 5'd0) begin
                bit_cnt <= 5'd31;

                if (word_cnt == WORDS_PER_PACKET-1) begin
                    // Finished last word → mark transfer done
                    transfer_active <= 1'b0;

                    // advance line/ramp counters for NEXT packet
                    if (line_cnt == LINE_MAX) begin
                        line_cnt <= 16'd0;
                        ramp_cnt <= (ramp_cnt == RAMP_MAX) ? 16'd0
                                                           : ramp_cnt + 16'd1;
                    end else begin
                        line_cnt <= line_cnt + 16'd1;
                    end
                end
                else begin
                    word_cnt <= word_cnt + 6'd1;
                    shreg    <= packet_word(word_cnt + 6'd1); // load next word
                end
            end
            else begin
                bit_cnt <= bit_cnt - 5'd1;
            end
        end
        // --------------------------------------------------------------
        //  Otherwise: CS is LOW or we've already finished this packet
        // --------------------------------------------------------------
    end

endmodule
