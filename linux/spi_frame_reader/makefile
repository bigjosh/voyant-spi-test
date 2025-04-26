# simplest possible Makefile for spi_frame_reader.c
TARGET := spi_frame_reader       # name of the final executable
CC     = aarch64-linux-gnu-gcc                    # use your toolchain by overriding, e.g.  CC=aarch64-linux-gnu-gcc
CFLAGS = -O2 -Wall              # tweak or add flags as you wish

$(TARGET): spi_frame_reader.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(TARGET)

.PHONY: clean
