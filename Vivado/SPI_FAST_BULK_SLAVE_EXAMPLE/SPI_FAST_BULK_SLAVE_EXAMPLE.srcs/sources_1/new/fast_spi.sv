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

    // ---------------------------------------------------------------------
    //  Internal tri-state drivers for the four IO lines
    // ---------------------------------------------------------------------
    //  Each IO pin gets:
    //      • out val
    //      • output-enable (active-HIGH = we drive, LOW = high-Z)
    //  (Input is simply the value read from the inout when OE=0)
    // ---------------------------------------------------------------------

    // IO0 ------------------------------------------------------------------
    logic io0_out, io0_oe;
    assign qpsi_dat0 = io0_oe ? io0_out : 1'bz;
    wire  io0_in     = qpsi_dat0;

    // IO1 ------------------------------------------------------------------
    logic io1_out, io1_oe;
    assign qpsi_dat1 = io1_oe ? io1_out : 1'bz;
    wire  io1_in     = qpsi_dat1;

    // IO2 ------------------------------------------------------------------
    logic io2_out, io2_oe;
    assign qpsi_dat2 = io2_oe ? io2_out : 1'bz;
    wire  io2_in     = qpsi_dat2;

    // IO3 ------------------------------------------------------------------
    logic io3_out, io3_oe;
    assign qpsi_dat3 = io3_oe ? io3_out : 1'bz;
    wire  io3_in     = qpsi_dat3;

    // ---------------------------------------------------------------------
    //  Very small control state-machine
    // ---------------------------------------------------------------------
    typedef enum logic [2:0] {
        ST_IDLE          = 3'd0,   // Waiting for 1st bit of a new command
        ST_CMD_CAPTURE   = 3'd1,   // Shifting in 8-bit op-code
        ST_JEDEC_TX      = 3'd2,   // Streaming 24-bit JEDEC ID (single-bit IO1)
        ST_QOFR_ADDR     = 3'd3,   // Capturing 24-bit address (discarded)
        ST_QOFR_DUMMY    = 3'd4,   // 8 dummy cycles before data phase
        ST_QOFR_DATA     = 3'd5    // Infinite x4 data stream
    } state_t;

    state_t state, nxt_state;
    
    
    // Just se we can see whats going on
    assign debug1 = (state == ST_CMD_CAPTURE) ? 1'b1 : 1'b0 ;
    assign debug2 = (state == ST_JEDEC_TX   ) ? 1'b1 : 1'b0 ;
    

    // -------------------------------------------------------------
    //  Bit counters & shift registers
    // -------------------------------------------------------------
    logic [7:0]  cmd_shift;       // For capturing op-code (MSB first)
    logic [4:0]  bit_cnt;         // Up to -- 24 address bits, 8 dummy, etc.

    logic [23:0] jedec_shift;     // For transmitting JEDEC ID (MSB first)
    logic [63:0] data_shift;      // Pattern shifter for Quad-Read data nibble

    // LED heartbeat ---------------------------------------------------------
    always_ff @(posedge qspi_clk) begin
        if (state == ST_QOFR_DATA)
            led <= ~led;          // Blink while streaming data
    end

    // gnd pin is always tied low -------------------------------------------
    assign gnd = 1'b0;
    
    // -----------------------------------------------------------------------
    //  Synchronous control logic
    //  * Everything driven on the rising edge of qspi_clk while CS_N is LOW *
    //  * A rising edge of CS_N **asynchronously** resets back to IDLE       *
    // -----------------------------------------------------------------------
    always_ff @(posedge qspi_clk, posedge qspi_cs) begin
        // ---------- CS_N de-asserted → abort current transaction ----------
        if (qspi_cs) begin
            state       <= ST_IDLE;
            bit_cnt     <= '0;
            cmd_shift   <= '0;
            jedec_shift <= JEDEC_ID;
            data_shift  <= DATA_PATTERN;

            // All outputs high-Z
            io0_oe <= 0; io1_oe <= 0; io2_oe <= 0; io3_oe <= 0;
            io0_out<=0;  io1_out<=0;  io2_out<=0;  io3_out<=0;
        end
        // ----------- Normal operation (CS_N held LOW) ---------------------
        else begin
            case (state)
            // ---------------------------------------------------------
            ST_IDLE: begin
                // Begin capturing an 8-bit command (MSB first) on IO0
                state     <= ST_CMD_CAPTURE;
                cmd_shift <= {cmd_shift[6:0], io0_in}; // shift-in bit-7 first
                bit_cnt   <= 3'd1;                     // already captured 1 bit
            end

            // ---------------------------------------------------------
            ST_CMD_CAPTURE: begin
                cmd_shift <= {cmd_shift[6:0], io0_in};
                bit_cnt   <= bit_cnt + 1;

                if (bit_cnt == 3'd7) begin     // All 8 bits captured
                    unique case ( {cmd_shift[6:0], io0_in} ) // next-clock value
                        OPCODE_JEDEC_ID:  state <= ST_JEDEC_TX;
                        OPCODE_QOFR:      state <= ST_QOFR_ADDR;
                        default:          state <= ST_IDLE; // Unsupported op
                    endcase
                    bit_cnt <= '0;         // Reset counter for next state
                    jedec_shift <= JEDEC_ID;  // Reload constant for each read
                    data_shift  <= DATA_PATTERN;
                end
            end

            // ---------------------------------------------------------
            ST_JEDEC_TX: begin
                // --- DRIVE ONLY IO1 (classic MISO) ------------------
                io0_oe <= 0;
                io1_oe <= 1; io1_out <= jedec_shift[23]; // MSB first
                io2_oe <= 0; io3_oe <= 0;

                // Rotate left 1 bit so next MSB is ready
                jedec_shift <= jedec_shift[22:0] << 1 ;
                bit_cnt     <= bit_cnt + 1;

                if (bit_cnt == 5'd23) begin   // Sent 24 bits
                    state   <= ST_IDLE;       // Remain responsive to op-codes
                    bit_cnt <= '0;
                    io1_oe  <= 0;             // Release IO1 when done
                end
            end

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
            endcase
        end
    end

endmodule
