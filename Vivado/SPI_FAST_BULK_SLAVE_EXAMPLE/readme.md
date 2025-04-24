This is the constraints and Verilog code to be a stand-in for the Lidar hardware. It generates test data rather than voxels, but it should be easy to plug this into the Lidar peak FIFO. 


It uses 3 pins on the FPGA that are connected to corresponding pins on the iMX8P...

| Signal | Direction | 
| - | - |
| `CLK` | FPGA <- MCU  | 
| `MISO` | FPGA -> MCU |
| `CS` | FPGA <- MCU | 

TE0703 Carrier Board Connections

| Signal | FPGA Package Pin | Header Location |
| - | - | - |
| `MISO` | M16 | J2-A7 |
| `CS` | L15 | J2-B6 |
| `CLK` | K17 | J2-B8 | 
| `GND` | J17 | J2-B7 |


IMPORTANT NOTE: The `CLK` pin is currently different than the one used on the Voyant board. This is because the Voyant board uses a pin that is not available on the FPGA TE0703 test board. You must change the pin assignment in the constraints file before running this code on a Voyant board!

For this test code running on the carrier board, we use `B15_L21_P` because it has no connection on the Voaynt PCB so if the wrong code accidentally gets install it will not harm anything. It is also nice that it shows up on the carrier board headers right near the other pins. 

We also add an IO pin that is always low to the header at J2-B7 just so we have a convenient and stable ground. This pin is no-connection on the Voyant board, so should not cause any issues if carrier version of this code accidentally gets deployed there. 
