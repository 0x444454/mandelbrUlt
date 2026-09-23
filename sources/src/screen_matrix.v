// screen_matrix.v
// 
// Implements a 44x25 character screen matrix (C64 screen codes).
// Each character is rendered as an 8x8 glyph.
// The video path doubles each char pixel horizontally, so the matrix spans the full 704-sample raster.
//
// Default contents:
//   - Filled with SPACE (screen code 32)
//   - Row 0, column 0: "DDT'S MANDELBRULT - 2026-09-19"
//   - Row 2, column 0: "20 HARDWARE MANDEL ENGINES". TODO: Use actual MANDEL_CORES value defined in "top.v".
//   - Rows 0..24 are addressable; unspecified cells are spaces.
//   - Visibility is controlled using text_enable.
//
// IMPORTANT:
//   This file stores C64 screen codes (not PETSCII, not ASCII).
//   - Alphabetics: 'A' = 1, 'B' = 2, ... 'Z' = 26.
//   - Space is code 32.

// Keep the cy * 44 character-address network in LUT carry chains to avoid Vivado "stealing" DSP from mandel engines.

(* use_dsp = "no" *)
module screen_matrix (
  input  wire       text_enable,
  input  wire [5:0] cx,   // 0..43
  input  wire [4:0] cy,   // 0..24
  output wire [7:0] code
);

  localparam integer W = 44;
  localparam integer H = 25;
  localparam integer N = W*H; // 1100

  reg [7:0] mem [0:N-1];

  integer i;
  integer idx;

  initial begin
    // Fill with spaces (code 32)
    for (i = 0; i < N; i = i + 1) begin
      mem[i] = 8'd32;
    end

    // Row 0, column 0: "DDT'S MANDELBRULT - 2026-09-19"
    idx = 0;
    mem[idx +  0] = 8'd4;  mem[idx +  1] = 8'd4;  mem[idx +  2] = 8'd20;
    mem[idx +  3] = 8'd39; mem[idx +  4] = 8'd19; mem[idx +  5] = 8'd32;
    mem[idx +  6] = 8'd13; mem[idx +  7] = 8'd1;  mem[idx +  8] = 8'd14;
    mem[idx +  9] = 8'd4;  mem[idx + 10] = 8'd5;  mem[idx + 11] = 8'd12;
    mem[idx + 12] = 8'd2;  mem[idx + 13] = 8'd18; mem[idx + 14] = 8'd21;
    mem[idx + 15] = 8'd12; mem[idx + 16] = 8'd20; mem[idx + 17] = 8'd32;
    mem[idx + 18] = 8'd45; mem[idx + 19] = 8'd32; mem[idx + 20] = 8'd50;
    mem[idx + 21] = 8'd48; mem[idx + 22] = 8'd50; mem[idx + 23] = 8'd54;
    mem[idx + 24] = 8'd45; mem[idx + 25] = 8'd48; mem[idx + 26] = 8'd57;
    mem[idx + 27] = 8'd45; mem[idx + 28] = 8'd49; mem[idx + 29] = 8'd57;

    // Row 2, column 0: "20 HARDWARE MANDEL ENGINES"
    idx = 2*W;
    mem[idx +  0] = 8'd50; mem[idx +  1] = 8'd48; mem[idx +  2] = 8'd32;
    mem[idx +  3] = 8'd8;  mem[idx +  4] = 8'd1;  mem[idx +  5] = 8'd18;
    mem[idx +  6] = 8'd4;  mem[idx +  7] = 8'd23; mem[idx +  8] = 8'd1;
    mem[idx +  9] = 8'd18; mem[idx + 10] = 8'd5; mem[idx + 11] = 8'd32;
    mem[idx + 12] = 8'd13; mem[idx + 13] = 8'd1; mem[idx + 14] = 8'd14;
    mem[idx + 15] = 8'd4; mem[idx + 16] = 8'd5; mem[idx + 17] = 8'd12;
    mem[idx + 18] = 8'd32; mem[idx + 19] = 8'd5; mem[idx + 20] = 8'd14;
    mem[idx + 21] = 8'd7; mem[idx + 22] = 8'd9; mem[idx + 23] = 8'd14;
    mem[idx + 24] = 8'd5; mem[idx + 25] = 8'd19;
  end

  // idx = cy*44 + cx = (cy<<5) + (cy<<3) + (cy<<2) + cx
  wire [10:0] idx_rd = ( {6'd0, cy} << 5 ) +
                       ( {6'd0, cy} << 3 ) +
                       ( {6'd0, cy} << 2 ) +
                       {5'd0, cx};

  assign code = text_enable && (cx < W) && (cy < H) ? mem[idx_rd] : 8'd32;

endmodule
