# BITSTREAM IS HERE

- **mandelbrUlt.bit** : Bitstream for Commodore 64 Ultimate.

NOTE: This bitstream is for the C64 Ultimate with 50T (XC7A50T) FPGA board.  
If you have a Commodore 77 with 100T FPGA board, build from sources.

# HOW TO RUN

Check this project to setup your C64U for FPGA development:  

https://github.com/0x444454/look_ma_no_vic

Use Vivado to program your C64U board using the bitstream file.  
In the "Flow Navigator": "Program and Device" -> "Open Hardware Manager" -> "Program Device" -> [your board].  
Select the path of the bitstream file.  
Click the "Program" button on the UI.  

NOTE: If "Program Device" is not active, check that your debug interface USB drivers have been correctly installed.  

# LICENSE

Creative Commons, CC BY

https://creativecommons.org/licenses/by/4.0/deed.en

