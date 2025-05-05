# voyant-spi-test
Demo testing ~40Mhz bandwidth SPI from Atrix7 FPGA to i.MX8M ARM.

The purpose of this test is just to see if we have good signal integrity on the Voyant PCB for the `multi_spi_x` traces between the FPGA and the CPU. If yes, then still work to do- but if not then no point perusing this path!

# How to test on Voyant PCB

## Install
1. Download the [Latest release](https://github.com/OWNER/REPO/releases/latest) of this repo
2. Load `top.bit` into the FPGA.
3. Copy `spi_frame_reader` to anywhere on the SOM. 
4. `chmod +x spi_frame_reader`

## Test

I used the `voyant-fixr.dtb` so as long as your board also has that device tree and there have not been any changes to the SPI stuff then this should work out of the box. LMK if you want a script to double check this.

A good start is...

`./spi_frame_reader -c 40 -s 1000000 -v 0 -h`

This will read 40 packets from the FPGA (each packet is 24x32 bits long) at clk speed 1Mhz and halt if there are any problems detected. Verbosity is turned completely off because printing slows things down a lot.

If that works, next I'd try revving up the speed...

`./spi_frame_reader -c 40 -s 39900000 -v 0 -h`

If that works, then I'd try a much longer test like...

`./spi_frame_reader -c 1000000 -s 39900000 -v 0 -h`

(Note that you will see "SEQ resets" when you send a lot of packets. These are caused by a known driver issue 
and can be safely ignored for now. )

If it can do that with no errors, that is a good sign! I get about 25-30us per packet on my setup, but this is with stock linux and with lots of possible optimizations available. Between speeding things up here and trimming things down in the peak data fields, this could be a plausible solution.

Note that the tool and the hardware can go up to 50Mz, but above ~39.9Mhz  you weirdly start getting weirdness and that weirdness can be persistent even after you drop back down to a lower speed, so I would stay below 40MHz in testing. Probably a driver issue? See optimizations below. 

LMK what you find or if any questions come up!

# Protocol info

Test protocol here, in case you care.

## SPI Mode

We use SPI mode 0x01 on both the FPGA and the ECSPI:
```
Mode 1 (CPOL=0, CPHA=1):
Clock is idle high, data is sampled on the falling edge of the clock, and shifted out on the rising edge.
```

I picked posedge clk so that the rising clock can trigger the next bit to be loaded on MISO, even on the first bit of a packet.

The CS is active low, which matches the settings you already had in the `fix-voyant.dto` device tree so I kept them, but at some 
point we might want to switch to CS low so it can be open drain so the FPGA can pause the ECSPI (would require 
driver modifications). 

## Packet format

Each packet has a quadlet sequence number followed by 23 quadlets of test data. The sequence number is there so
the receiver can detect dropped packets. The test data is just a fixed set of mixed numbers that both sides know and so can receiver can check for corruption in transit. 

# Theoretical bandwidth calculations

Constraint is we need to push a packet every 16.384us. 

Assuming the SPI clock runs continuously...

At 40Mhz, a 22 word packet takes (1 / (40 Mhz)) * 32 * 20 = 16 microseconds on the wire

At 50Mhz, a 26 word packet takes ((1 / (50 Mhz)) * 32 * 26 = 16.64 microseconds on the wire

If we no not send packets during the "margin" at the sides of the frame when the mirror is changing direction,
then we can take more time to drain each "field" from the FIFO so data rate can be lower or packets can be longer.

# Optimizations

## Expand XFER BUF in kernal

With stock kernal, we get a gap every 4096 bits...
![](image-7.png)
It is ~450us at 4Mhz

![](image-8.png)
And about ~100-200us at 40Mhz

To fix this, we need to increase the size of the XFER buffer in `spidev`. I think this could be a setting to the kernel?
https://community.toradex.com/t/maximum-transfer-size-4096-bytes-with-spidev-driver-for-spi-on-colibri-imx6/7637/2

## Remove gap between 32 bit words

Right now there is a ~1us gap between 32 bit words at 40Mhz...
![](image-6.png)
Figure out where that is from? A good test would be to brute force keep the FIFO stuffed by spinning on the ready bit and see if that makes it go away. 

It increases as CLK rate goes down, so probably happening inside the ECSPI. Maybe increase the burst_size register inside the ECSPI would fix this? The driver currently seams to max at 32 bits. 

## Remove gap between CS and posedge of CLK

This is probably happening in the driver so we could probably fix it, but it is only ~50us (clk speed invariant) and we only incur it once per CS. 

## Figure out why things go wonky at 40Mhz

Maybe some kind of clock interaction? Need to dig in with a kernel module and a fast logic analyzer and track this down. 

## Remove gap between bytes at 50Mhz

![](image-9.png)
If we could fix this, then we'd get instant 25% boost. 

Hard to guess where to is coming from? Maybe the driver or DMA can't keep up... but the ECSPI FIFO is 32 bits wide so maybe the driver is setting the bust down to 8 bits for some reason? Need to dig. 

And ooof, seams like once you cross the 50MHz line, then you keep the 8-bit gaps even after you drop back down to 40Mhz. AND IF YOU REBOOT THEN THE SPIDEV IS DEAD! NEED TO POWER CYCLE TO GET 40MHZ BACK. :/

# Testing with TE0703 FPGA and Dhalia CPU carrier boards

This is the setup on my bench. It should be using the same pins as the Voyant PCB based on the schematics I have. 

### 1. Make 4 connections between the boards...

| Signal | Dhalia Header | TE0703 Header |
| - | - | - | 
| `MISO` | X20 23 | J2-A7 | 
| `CS` | X20 25 | J2-B6 |
| `CLK` | X20 22 | J2-B8 | 
| `GND` | X20 21 | J2-B7 |
| `CS`  | X20 30 | J2-B6 |

#### Dhalia header locations:

![](image-5.png)

#### TE0703 header locations:

![alt text](image-4.png)
(Note that there are no silk markings on my board!)

I used 6 inch jumper wires and it seems to work fine. I did need to solder headers onto the TE0703 
board. 

