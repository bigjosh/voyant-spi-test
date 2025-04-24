package voyant_spi_types_pkg;                 // (optional) keep things tidy
  // Parameters that determine the shape
  parameter int WORDS     = 32;
  parameter int WORD_BITS = 32;

  // Packed-array typedef: WORDS × WORD_BITS
  typedef logic [WORDS-1:0][WORD_BITS-1:0] payload_t;
endpackage

