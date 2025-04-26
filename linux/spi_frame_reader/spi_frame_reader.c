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

 #define WORDS_PER_PAYLOAD 24           // Must match the number of words defined in the FPGA's payload

 #define DEFAULT_DEV_PATH       "/dev/spidev1.0"
 #define DEFAULT_SPEED_HZ       40000000            /* 40 MHz  */
 #define DEFAULT_PACKET_COUNT   1                   /* 0 = forever */

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

 static void usage(const char *prog)
 {
     fprintf(stderr,
         "  -d  SPI device node     (default %s)\n"
         "  -s  SPI clock speed Hz  (default %u)\n"
         "  -c  Packets to receive  (default %u)\n"
         "  -v  Verbosity. 0=Total run, 1=Report errors, 2=Each packet, 3=Raw data (default 1)\n"
         "\nVerbosity>1 will reduce max bandwith.\n",
         DEFAULT_DEV_PATH, DEFAULT_SPEED_HZ, DEFAULT_PACKET_COUNT);
     exit(EXIT_FAILURE);
 }

 uint32_t packet_count = DEFAULT_PACKET_COUNT;           // How many packets should we pull in before exiting?

 uint32_t verbosity = 1;                                 // How much should we print out? Default to show print errors while test in progress.
 
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

            case 'v': {
                char *end;
                unsigned long tmp = strtoul(optarg, &end, 0);
                if (*end || tmp > 3) usage(argv[0]);
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
 
     uint8_t mode = SPI_MODE_1 | CS_POLARITY; 
     uint8_t bits = 32;  // This is the highest the current driver will let us go. The ECSPI hardware can go higher. 
 
     printf("Device %s @ %u Hz  | Words per payload %u | Packet Len %lu bytes | Receving %u packets\n",
            dev_path, speed, WORDS_PER_PAYLOAD , BYTES_PER_PACKET , packet_count );
 
     /* --- configure spidev ------------------------------------------- */
     if (ioctl(fd, SPI_IOC_WR_MODE, &mode)            == -1) die("SPI_IOC_WR_MODE");
     if (ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, &bits)   == -1) die("SPI_IOC_WR_BITS");        
     if (ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, &speed)   == -1) die("SPI_IOC_WR_SPEED");
 
     uint8_t *tx = calloc(BYTES_PER_PACKET, 1);           /* This is just for the SPI to have something to send (to nowhere) */
     if (!tx) die("malloc");

     packet_t rx_packet_buffer;         // Receive buffer for the SPI data. Into the struct so we can effciently pull data out.
 
     struct spi_ioc_transfer tr = {
         .tx_buf        = (unsigned long)tx,                  // Not needed?
         .rx_buf        = (unsigned long)&rx_packet_buffer,   // This is where the data will be read into
         .len           = BYTES_PER_PACKET,
         .speed_hz      = speed,
         .bits_per_word = bits,
         .cs_change     = 0,   /* Keep CS asserted the whole time (Do not assert/dessert with each write)*/
         .delay_usecs   = 0
     };
 
     uint32_t packet_good   = 0;          // How many packets have we received without errors
     uint32_t packet_errors = 0;          // How many packets have we received that are corrupted?

    struct timespec start_time, end_time;

    clock_gettime(CLOCK_MONOTONIC, &start_time);      

    for (uint32_t pkt = 0; packet_count == 0 || pkt < packet_count ; ++pkt) {           // 0=forever

        /* --- single SPI transaction = one full packet -------------------- */
        if (ioctl(fd, SPI_IOC_MESSAGE(1), &tr) < 1) die("SPI_IOC_MESSAGE");


        packet_good++;


        if (verbosity > 1) {
            printf(" Packet %9u | SEQ:%9u\n",
                    pkt , rx_packet_buffer.seq
            );


            if (verbosity > 2) {

                for (uint8_t i = 1; i < WORDS_PER_PAYLOAD; ++i) {
                    printf("    Word [%2u]: %08x\n", i,  rx_packet_buffer.payload.data[i]);
                }                

            }

        }

    }

    clock_gettime(CLOCK_MONOTONIC, &end_time);

    if (packet_errors>0) {
        printf("ERRORS: %u corrupted packets!\n", packet_errors);
    } else {
        printf("No errors\n");
    }

    unsigned long elapsed_time_us;
    elapsed_time_us = (end_time.tv_sec - start_time.tv_sec) * 1000000 + ((end_time.tv_nsec - start_time.tv_nsec) / 1000);

    printf("Total time: %lu us | %u good packets | %.03f us/packet\n",
            elapsed_time_us, packet_good,  (elapsed_time_us / (packet_good *1.0) ) );
    
    free(tx); close(fd);
    return 0;
}
 