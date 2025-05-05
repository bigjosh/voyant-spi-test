# Setting up Linux on the SOM

We need to install a device tree overlay into Linux that has the QSPI device and pin info.

## Install on a normal target running Linux

Just compile the `custom-overlay.dts` into a dtb, copy that dtb to the target and add it to the overlays list. 

## Install on a Toradex Dhalia 

1. Download the `zst` image from the releases of this repo.
2. [Put the board into EZ Install Mode](https://developer.toradex.com/hardware/hardware-resources/recovery-mode/imx-ti-recovery-mode/?module=verdin_imx8mp&carrier=dahlia#start)
3. Put the new image onto the board. 

## If you are using Torizon corebuilder stuff

This was a huge pain to figure out, so this procedure is here mostly for me to remember how I did it. 

1. Install all the corebuilder stuff on a dev machine. (Once, described below)
2. Download a suitable image from Toridex. 
2. Run `source tcb-env-setup.sh`. I think this has to be in the same dir as the `tcbuild.yaml` (in this repo). Note that you have to do this every time you start a new shell. 
3. `torizoncore-builder build --force`. The `force` tells it to overwrite the output dir if it is already there. 

That will create an output dir called `torizon-docker-verdin-imx8mp-voyant-qspi`, and in that dir there is a `zst` file that has the image in it. 

You can deploy to a running SOM with this command...
```
torizoncore-builder deploy voyant-flexspi-1 --remote-host 10.0.0.47 --remote-username torizon --remote-password nancy --reboot
```
(replace IP, User, and Pass)

### Installing Torizon corebuilder stuff

