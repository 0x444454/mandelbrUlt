# HOW TO BUILD FROM SOURCES

## Requirements

- Xilinx Vivado (tested on version 2025.2).

## Open the project file

Open the ```mandelbrUlt.xpr``` project file.

NOTE: By default, the project is configured for the __Commodore 64 Ultimate__ with 50T FPGA board.  
If instead you have a __Commodore 77__ with 100T FPGA board, change the FPGA type to XC7A100T and set ```MANDEL_CORES = 40``` in the [top.v](src/top.v) file to reach 4 GigaIters/s on the 100T.  

## Build
In the "Flow Navigator": "Program and Device" -> "Generate Bitstream".
When done, Vivado will show the "Write Bitstream Complete" in the upper right corner of the UI.

## Run

Once the bitstream has been built, in the "Flow Navigator": "Program and Device" -> "Open Hardware Manager" -> "Program Device" -> [your board].  

NOTE: If "Program Device" is not active, check that the Basys3 USB drivers have been correctly installed.

# LICENSE

Creative Commons, CC BY

https://creativecommons.org/licenses/by/4.0/deed.en

Please add a link to this github project.
