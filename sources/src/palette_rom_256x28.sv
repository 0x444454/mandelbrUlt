// Fixed Mandelbrot palette converted at build time to the values required by our analog video path.
// We use YUV in ROM, so no need for RGB to YUV matrix calc.
//
// 256 entries x 28 bits. Packed word:
// {picture_luma[7:0], U[9:0], V[9:0]}.
//
module palette_rom_256x28 (
    input  logic [7:0]        addr,
    output wire [7:0]         picture_luma,
    output wire signed [9:0]  palette_u,
    output wire signed [9:0]  palette_v
);

    (* rom_style = "distributed" *) logic [27:0] rom [0:255];
    wire [27:0] rom_word;

    assign rom_word = rom[addr];

    initial $readmemh("palette_yuv_256.hex", rom);

    assign picture_luma = rom_word[27:20];
    assign palette_u    = $signed(rom_word[19:10]);
    assign palette_v    = $signed(rom_word[9:0]);

endmodule
