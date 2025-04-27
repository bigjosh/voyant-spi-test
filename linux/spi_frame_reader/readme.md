To compile:

`aarch64-linux-gnu-gcc -Wall -O2 -static spi_frame_reader.c -o spi_frame_reader`

...or just `make`.

You need the static so you don't care so much about small Yokto version mismatches (otherwise you basically gotta compile on the same machine that built the Linux image). 

Then copy the file over to the i.MX8MP and don't forget to `chmod +x spi_packet_reader` it. 

In VS CODE the default build works assuming you are attached to a WSL with all the Toradex linux files. 

VS CODE also has a Task to copy the file to the target. It currently has my target IP hardcoded, but you can change that in `tasks.json`.