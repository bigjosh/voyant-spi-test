To compile:
aarch64-linux-gnu-gcc -Wall -O2 -static spi_frame_reader.c -o spi_frame_reader

You need the static so you don't care so much about small Yokto version mismatches (otherwise you basically gotta compile on the same machine that built the Linux image). 

Then copy the file over to the i.MX8MP and don't forget to `chmod +x spi_packet_reader` it. 