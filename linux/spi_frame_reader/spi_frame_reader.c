/*
 * spi_frame_reader.c – quick‑n‑dirty test for Artix‑7 SPI‑slave streamer
 * note that you must have the matching send code running on the FPGA.
 *
 * Usage:
 *   ./spi_frame_reader                      # defaults /dev/spidev1.0 @ 40 MHz
 *   ./spi_frame_reader -d /dev/spidev1.1    # pick another device
 *   ./spi_frame_reader -s 20000000          # 20 MHz
 */

 /* Note to me: To cross compile this in VS CODE, press Control+Shift+B. That uses tasks.json.*/

 #define _GNU_SOURCE
 #include <errno.h>
 #include <fcntl.h>
 #include <getopt.h>
 #include <linux/spi/spidev.h>
 #include <stdint.h>
 #include <stdio.h>
 #include <stdlib.h>
 #include <string.h>
 #include <sys/ioctl.h>
 #include <unistd.h>
 #include <stdint.h>
 #include <assert.h>   // pulls in the macro form of _Static_assert
 #include <time.h>

 #define CS_POLARITY 0  // 1=active high, 0=active low
                        // Currently the FPGA is set to active low, so this is 0. 
                        // Soon we will want to switch to active high so the FPGA keep the line low to pause the
                        // transfer. 
 
 // Note that `word` = 32 bits

 #define WORDS_PER_PAYLOAD 23           // Must match the number of words defined in the FPGA's payload. Probably slightly more effcicient for this to be odd so total packet size is 64 bit alighned?

 #define DEFAULT_DEV_PATH       "/dev/spidev1.0"
 #define DEFAULT_SPEED_HZ       40000000            /* 40 MHz  */
 #define DEFAULT_PACKET_COUNT   1                   /* 0 = forever */

 #define MAX_SPI_DEV_IOCTL_XFER 4096          /* current /sys/module/spidev/parameters/bufsiz */

 /* 

|**Pass a kernel-cmdline option (or rebuild)**
 spidev is built-in (`CONFIG_SPI_SPIDEV=y`)
 Add `spidev.bufsiz=65536` to the kernel command line (e.g. in U-Boot: `setenv bootargs $bootargs spidev.bufsiz=65536; saveenv`)
 or change the `bufsiz` line in `spidev.c` and recompile the kernel. 

 **Tip:** keep the new size a power of two (16 k, 32 k, 64 k) and under whatever limit your SPI controller driver reports via `spi_max_transfer_size()`.

 */


 #define min(a,b) ((a) < (b) ? (a) : (b))   /* biggger is more efficient because hopefully DMA kicks in and less send transactions */

 #define BYTES_PER_WORD     4            /* Define our terms. */
 
 static void die(const char *msg)
 {
     perror(msg);
     exit(EXIT_FAILURE);
 }

// This has to match the sending code in the FPGA

typedef struct  {
    uint32_t data[WORDS_PER_PAYLOAD];   
} payload_t;

typedef struct {                     // Words:
    uint32_t seq;                   
    payload_t payload;
 } packet_t;                       


 #define BYTES_PER_PACKET (sizeof(packet_t))
 #define BITS_PER_PACKET (sizeof(packet_t) * 8)

 static_assert( BITS_PER_PACKET <= (32*36) , "packet_t must be less than 32*36 bits to fit into the ECSPI hardware buffer.");

/*
    // This is the data type used in the FPGA design, here for reference.

    typedef logic [BITS_PER_WORD-1:0] u32_t;          // 4-state, unsigned

    // A payload is the useful data in a packet, does not include the CRC that will be appened before transmision.
    // Note that the major index starts at 0, so index 0 will be MSB and go out the wire first.
    typedef logic [0:WORDS_PER_PAYLOAD-1][BITS_PER_WORD-1:0] payload_t;
    
    // Easy to eyeball stuff. 
    payload_t test_payload = '{

        0       : 32'h5555_5555,      // override element 
        1       : 32'hAAAA_AAAA,      // override element                 
        2       : 32'hFFFF_FFFF,      // override element
        3       : 32'h0000_0000,       // override element
        4       : 32'h0000_0001,      // override element
        5       : 32'h0000_0000,       // override element                
        6       : 32'hFFFF_FFFF,       // override element
        7       : 32'hFFFF_FFFE,      // override element
        8       : 32'hFFFF_FFFF,       // override element        
        9       : 32'hABCD_EF00,      // override element 
       10       : 32'h9876_5432,      // override element 
       11       : 32'h2468_2468,       // override element 
       12       : 32'hFFFF_FFFF,      // override element
       13       : 32'h0000_0000,       // override element
       14       : 32'h0000_0001,      // override element
       15       : 32'h0000_0000,       // override element                
       16       : 32'hFFFF_FFFF,       // override element
       17       : 32'hFFFF_FFFE,      // override element
       18       : 32'hFFFF_FFFF,       // override element                
       19       : 32'h1234_ABCD,      // override element
           
        default : 32'hDEAD_BEEF       // fill any trailing words with dead_beef                   
                        
    };       

*/

// Here is the C translation of the above payload.

/* 0xDEADBEEF is the “padding” word used by the FPGA design. */
#define PADWORD 0xDEADBEEF

/* WORDS_PER_PAYLOAD is already a compile-time constant (23 in your RTL). */
static const uint32_t test_payload[WORDS_PER_PAYLOAD] = {
    /* 1.  Fill the whole array with PADWORD ............................... */
    [0 ... WORDS_PER_PAYLOAD - 1] = PADWORD,

    /* 2.  Override the meaningful entries ................................ */

    [ 0] = 0x55555555,
    [ 1] = 0xAAAAAAAA,
    [ 2] = 0xFFFFFFFF,
    [ 3] = 0x00000000,
    [ 4] = 0x00000001,
    [ 5] = 0x00000000,
    [ 6] = 0xFFFFFFFF,
    [ 7] = 0xFFFFFFFE,
    [ 8] = 0xFFFFFFFF,
    [ 9] = 0xABCDEF00,
    [10] = 0x98765432,
    [11] = 0x24682468,
    [12] = 0xFFFFFFFF,
    [13] = 0x00000000,
    [14] = 0x00000001,
    [15] = 0x00000000,
    [16] = 0xFFFFFFFF,
    [17] = 0xFFFFFFFE,
    [18] = 0xFFFFFFFF,
    [19] = 0x1234ABCD,
    /* the rest (13 … 22) stay 0xDEADBEEF */
};


 static void usage(const char *prog)
 {
     fprintf(stderr,
         "  -d  SPI device node     (default %s)\n"
         "  -s  SPI clock speed Hz  (default %u)\n"
         "  -c  Packets to receive  (default %u)\n"
         "  -h  Halt on error, print offending packet\n"
         "  -v  Verbosity. 0=Total run, 1=Report errors, 2=Each busrt 3=Each packet, 4=Raw data (default 1)\n"
         "\nVerbosity>1 will reduce max bandwith.\n",
         DEFAULT_DEV_PATH, DEFAULT_SPEED_HZ, DEFAULT_PACKET_COUNT);
     exit(EXIT_FAILURE);
 }

 uint32_t packet_count = DEFAULT_PACKET_COUNT;           // How many packets should we pull in before exiting?

 uint32_t verbosity = 1;                                 // How much should we print out? Default to show print errors while test in progress.

 uint32_t halt_flag =0; 

 void print_packet(packet_t *pkt ) {
    printf("    RX       Expected\n");
    printf("    =======  ========\n");
    printf(" SQ-%08X xxxxxxxx\n", pkt->seq );

    for (int i = 0; i < WORDS_PER_PAYLOAD; i++) {
        printf(" %2.2u-%08X %08X\n", i , pkt->payload.data[i] , test_payload[i]);
    }
    printf("\n");
}
 
 int main(int argc, char *argv[])
 {
    printf("SPI FPGA test, (c)2025 josh.com\n");
     /* --- parse command‑line ----------------------------------------- */
     const char *dev_path       = DEFAULT_DEV_PATH;
     uint32_t    speed          = DEFAULT_SPEED_HZ;
     uint32_t    packet_count   = DEFAULT_PACKET_COUNT;
     uint32_t    verbosity      = 0;
     int opt;
 
     while ((opt = getopt(argc, argv, "d:s:c:v:h")) != -1) {
         switch (opt) {

            case 'd': {
                dev_path = optarg;
                break;
            }

            case 's': {}
                char *end;
                unsigned long tmp = strtoul(optarg, &end, 0);
                if (*end || tmp == 0) usage(argv[0]);
                speed = (uint32_t)tmp;
                break;
            

                case 'c': {
                char *end;
                unsigned long tmp = strtoul(optarg, &end, 0);
                if (*end || tmp == 0) usage(argv[0]);
                packet_count = (uint32_t)tmp;
                break;
            }

            case 'h': {
                halt_flag = 1;
                break;
            }

            case 'v': {
                char *end;
                unsigned long tmp = strtoul(optarg, &end, 0);
                verbosity = (uint32_t)tmp;
                break;
            }
                            
            default: {
                usage(argv[0]);
            }
        }

     }

     // Code below based on spidev_test.c from the Linux kernel
 
     int fd = open(dev_path, O_RDWR);
     if (fd < 0) die("open");

     // In SPI mode 1, clock is idle low and data sampled on the falling edge.
     // This lets the FPGA shift out data the rising clock edge
 
     uint8_t mode = SPI_MODE_0 | CS_POLARITY; 
     uint8_t bits = 32;  // This is the highest the current driver will let us go. The ECSPI hardware can go higher. 
 
     printf("Device %s @ %u Hz  | Words per payload: %u | Receving %u packets | Payload bytes: %lu | Packet bytes: %lu \n",
            dev_path, speed, WORDS_PER_PAYLOAD , packet_count ,  sizeof(payload_t), sizeof(packet_t) );
 
     /* --- configure spidev ------------------------------------------- */
     if (ioctl(fd, SPI_IOC_WR_MODE, &mode)            == -1) die("SPI_IOC_WR_MODE");
     if (ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, &bits)   == -1) die("SPI_IOC_WR_BITS");        
     if (ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, &speed)   == -1) die("SPI_IOC_WR_SPEED");
 

     // Calculate how big a burst should be. (At least 1 packet, at most 1000 packets)
     // Burst must fit into the kernel buffer size (MAX_SPI_DEV_IOCTL_XFER)

     uint32_t packet_burst_count = min( packet_count,  (MAX_SPI_DEV_IOCTL_XFER / BYTES_PER_PACKET));   // How many full packets can fit into the kernel buffer?

     uint8_t *tx = calloc(packet_burst_count, sizeof(packet_t));           /* This is just for the SPI to have something to send (to nowhere) */
     if (!tx) die("malloc");

     packet_t rx_packet_buffer[packet_burst_count];         // Receive buffer for the SPI data. Into the struct so we can effciently pull data out.

 
     struct spi_ioc_transfer tr = {
        .tx_buf        = (unsigned long)tx,                  // Not needed?
        .rx_buf        = (unsigned long)&rx_packet_buffer,   // This is where the data will be read into
        //.len           = BYTES_PER_PACKET*packet_burst_count,
        .speed_hz      = speed,
        .bits_per_word = bits,
        .cs_change     = 0,   /* Keep CS asserted the whole time (Do not assert/dessert with each write)*/ // NOTE: THIS DOES NOT SEEM TO WORK 
        .delay_usecs   = 0
    };

 
     uint32_t seq_errors = 0;
     uint32_t seq_reset = 0;         // The ECSPI started a new transaction on us. 
     uint32_t corrupt_errors = 0;          // How many packets have we received that are corrupted?

     uint32_t packets_left = packet_count;           // How many packets are left to read?
     
     uint32_t next_seq = 1;           //We reset the FPGA on every run, so we start at 1.

     uint32_t packets_read = 0;           // How many packets have we read so far?

     printf("Starting packet loop |  Burst count: %u | Max kerel XFER buffer size: %u\n" ,
             packet_burst_count , MAX_SPI_DEV_IOCTL_XFER);  

    struct timespec start_time, end_time;

    clock_gettime(CLOCK_MONOTONIC, &start_time);     


    while ( packets_left > 0) {   
        
        if (verbosity >= 2) {    
            printf("-Burst: Packets left: %u | Next seq: %u\n", packets_left, next_seq);
        }

        uint32_t packets_in_this_burst = min( packet_burst_count, packets_left);   // How many packets should we read in this burst?

        tr.len = packets_in_this_burst*sizeof(packet_t);   // How many bytes should we read in this burst?

        /* --- single SPI transaction = one full packet -------------------- */
        if (ioctl(fd, SPI_IOC_MESSAGE(1), &tr) < 1) die("SPI_IOC_MESSAGE");

        // Process the packets in this burst

        for( uint32_t pkt = 0; pkt < packets_in_this_burst ; ++pkt) {           

            packets_read++;           // Increment the number of packets read so far. 

            if (verbosity >= 3 ) {
                printf("--Packet #%9u | SEQ:%9u\n",
                        packets_read , rx_packet_buffer[pkt].seq
                );
    
                if (verbosity >= 4) {
                    print_packet(&rx_packet_buffer[pkt] );
    
                }
    
            }

            // Check packet for errors

            uint32_t recieved_seq = rx_packet_buffer[pkt].seq;
    
            if (recieved_seq != next_seq) {           // If the packet is not the next expected packet

                if (recieved_seq == 1) {           
                    // If the seq is 1 then the ECSPI has reset CS and started a new transaction on us.
                    if (verbosity > 1) {
                        printf("ERROR: SEQ reset! Recieved:%u\n", recieved_seq);
                    }
                    seq_reset++;
                } else {

                    // nope this was a reall seq error
                    if (verbosity > 0) {                        
                        printf("ERROR: SEQ expected:%u Recieved:%u\n", next_seq, rx_packet_buffer[pkt].seq);
                    }

                    if (halt_flag) {
                        printf("Halting on SEQ error\n");
                        print_packet(&rx_packet_buffer[pkt]);
                        free(tx); close(fd);
                        exit(EXIT_FAILURE);
                    }
                    
                    seq_errors++;
                }

                
                next_seq = recieved_seq;       // sync to the current packet
            } 

            next_seq++;           // Increment the expected packet number        

            // TODO: Test the DEADBEEF words too    

            if (memcmp(&rx_packet_buffer[pkt].payload, test_payload, sizeof(test_payload)) != 0) {           // If the packet is not the expected packet
                if (verbosity > 1) {
                    printf("ERROR: Packet #%ucorrupted! Recieved:%u\n", packets_read , recieved_seq);
                }

                if (halt_flag) {
                    printf("Halting on DATA error\n");
                    print_packet(&rx_packet_buffer[pkt]);                    
                    free(tx); close(fd);
                    exit(EXIT_FAILURE);
                }
                corrupt_errors++;
            }

        }
        

        packets_left -= packets_in_this_burst;           // How many packets are left to read?
    }

    clock_gettime(CLOCK_MONOTONIC, &end_time);

    if (seq_errors>0) {
        printf("ERRORS: %u bad seq packets!\n", seq_errors);
    } else {
        printf("No missed sequences\n");
    }


    if (corrupt_errors>0) {
        printf("ERRORS: %u corrupted packets!\n", corrupt_errors);
    } else {
        printf("No corrupt packets\n");
    }

    if (seq_reset>0) {
        printf("WARN: %u SEQ resets!\n", seq_reset);
    } else {
        printf("No SEQ resets\n");
    }

    unsigned long elapsed_time_us;
    elapsed_time_us = (end_time.tv_sec - start_time.tv_sec) * 1000000 + ((end_time.tv_nsec - start_time.tv_nsec) / 1000);

    printf("Total time %lu us || %u  packets | %.03f us/packet\n",
            elapsed_time_us,   packet_count,  (elapsed_time_us / (packet_count *1.0) ) );
    
    free(tx); close(fd);
    return 0;
}
