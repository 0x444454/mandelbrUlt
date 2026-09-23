// Mandel framebuffer with a fixed 44x25 character overlay (using C64 font).
//
// Luma and PAL U/V are read from a preconverted palette; only subcarrier modulation remains in logic.
//
(* use_dsp = "no" *)
module mandel_video_pattern (
  input  wire       clk,
  input  wire       frame_start,
  input  wire       active,
  input  wire       in_sync,
  input  wire       burst_active,
  input  wire       line_odd,
  input  wire [9:0] x,
  input  wire [8:0] y,
  input  wire [7:0] fb_iter8,
  input  wire       text_enable,
  input  wire       palette_cycle_enable,
  output reg  [7:0] luma,
  output reg  [7:0] chroma,
  // DAC-enable/active-picture signal.
  output reg        image_active
);

  localparam integer IMG_LINES  = 256;
  localparam integer BORDER_TOP = 16;

  wire in_img_y = (y >= BORDER_TOP) &&
                  (y < (BORDER_TOP + IMG_LINES));
  wire img_active_now = active && in_img_y;

  // Port B of framebuffer_bram has one registered read cycle.
  // Delay only the picture coordinates to match fb_iter8.
  // The proven sync/burst controls below deliberately remain on their original timing path.
  reg        active_d1 = 1'b0;
  reg        line_odd_d1 = 1'b0;
  reg [9:0]  x_d1      = 10'd0;
  reg [8:0]  y_d1      = 9'd0;

  always @(posedge clk) begin
    active_d1 <= active;
    line_odd_d1 <= line_odd;
    x_d1      <= x;
    y_d1      <= y;
  end

  wire in_img_y_d1 = (y_d1 >= BORDER_TOP) &&
                     (y_d1 < (BORDER_TOP + IMG_LINES));
  wire img_active_d1 = active_d1 && in_img_y_d1;
  wire [8:0] y_img_d1 = y_d1 - BORDER_TOP;

  // Fixed char matrix overlay: 44 columns x 25 rows.
  // Each pixel of a 8x8 character is repeated for two PAL samples horizontally.
  // The char matrix starts at the upper-left of the image area.
  wire text_active_d1 = img_active_d1 && (x_d1 < 10'd704) &&
                        (y_img_d1 < 9'd200);
  wire [9:0] text_x_d1 = x_d1;
  wire [5:0] cx = text_x_d1[9:4];
  wire [4:0] cy = y_img_d1[7:3];
  wire [2:0] font_x = text_x_d1[3:1];
  wire [2:0] font_y = y_img_d1[2:0];

  wire [7:0] char_code;
  screen_matrix u_scr (
    .text_enable(text_enable), .cx(cx), .cy(cy), .code(char_code)
  );
  wire [10:0] font_addr = {char_code, font_y};
  wire [7:0] font_row;
  c64_font_rom u_font (.addr(font_addr), .data(font_row));
  wire font_bit = text_enable && img_active_d1 && text_active_d1 &&
                  (font_row[7 - font_x]);

  reg  [7:0] palette_rot = 8'd0;

  // Keep palette index 0 fixed and rotate indices 1..255 upward by one entry once per frame while the mode is enabled.
  // This way the Mandelbrot set color will always be black.
  
  always @(posedge clk) begin
    if (frame_start && palette_cycle_enable) begin
      if (palette_rot == 8'd254)
        palette_rot <= 8'd0;
      else
        palette_rot <= palette_rot + 8'd1;
    end
  end

  wire [7:0] palette_iter_minus1 = (fb_iter8 == 8'd0) ?
                                    8'd0 : (fb_iter8 - 8'd1);
  wire [8:0] palette_sum = {1'b0, palette_iter_minus1} +
                           {1'b0, palette_rot};
  wire [7:0] palette_index = (fb_iter8 == 8'd0) ? 8'd0 :
                             ((palette_sum >= 9'd255) ?
                              (palette_sum - 9'd255 + 9'd1) :
                              (palette_sum[7:0] + 8'd1));

  wire [7:0] picture_luma;
  wire signed [9:0] palette_u;
  wire signed [9:0] palette_v;
  palette_rom_256x28 u_palette (
    .addr(palette_index),
    .picture_luma(picture_luma),
    .palette_u(palette_u),
    .palette_v(palette_v)
  );

  // Sync remains at 0; blank/active black is 16 and text white is 80.

  localparam [7:0] BLANK_CODE  = 8'd16;
  localparam [8:0] LUMA_MAX    = 9'd80;
  localparam [7:0] CHROMA_ZERO = 8'd128;

  // Progressive PAL-like subcarrier from the 13.5 MHz DAC clock.
  //
  // The normal PAL frequency (4.43361875 MHz) does not close exactly on this progressive 864-sample line / 312-line frame.
  // Its phase therefore advances by almost 180 degrees between successive frames.
  // Use the line-locked value below (4.43359375 MHz = 283.75 cycles per line) and restart it at frame_start so every frame has the same phase origin.
  // TODO: Maybe this is not needed ?

  localparam [31:0] PAL_PHASE_INC = 32'd1410528901;
  reg [31:0] chroma_phase = 32'd0;

  always @(posedge clk) begin
    if (frame_start)
      chroma_phase <= 32'd0;
    else
      chroma_phase <= chroma_phase + PAL_PHASE_INC;
  end

  // And here's the sin tab.
  function signed [7:0] sine64;
    input [5:0] phase;
    begin
      case (phase)
        6'd 0: sine64 = 8'sd0;
        6'd 1: sine64 = 8'sd12;
        6'd 2: sine64 = 8'sd25;
        6'd 3: sine64 = 8'sd37;
        6'd 4: sine64 = 8'sd49;
        6'd 5: sine64 = 8'sd60;
        6'd 6: sine64 = 8'sd71;
        6'd 7: sine64 = 8'sd81;
        6'd 8: sine64 = 8'sd90;
        6'd 9: sine64 = 8'sd98;
        6'd10: sine64 = 8'sd106;
        6'd11: sine64 = 8'sd112;
        6'd12: sine64 = 8'sd117;
        6'd13: sine64 = 8'sd122;
        6'd14: sine64 = 8'sd125;
        6'd15: sine64 = 8'sd126;
        6'd16: sine64 = 8'sd127;
        6'd17: sine64 = 8'sd126;
        6'd18: sine64 = 8'sd125;
        6'd19: sine64 = 8'sd122;
        6'd20: sine64 = 8'sd117;
        6'd21: sine64 = 8'sd112;
        6'd22: sine64 = 8'sd106;
        6'd23: sine64 = 8'sd98;
        6'd24: sine64 = 8'sd90;
        6'd25: sine64 = 8'sd81;
        6'd26: sine64 = 8'sd71;
        6'd27: sine64 = 8'sd60;
        6'd28: sine64 = 8'sd49;
        6'd29: sine64 = 8'sd37;
        6'd30: sine64 = 8'sd25;
        6'd31: sine64 = 8'sd12;
        6'd32: sine64 = 8'sd0;
        6'd33: sine64 = -8'sd12;
        6'd34: sine64 = -8'sd25;
        6'd35: sine64 = -8'sd37;
        6'd36: sine64 = -8'sd49;
        6'd37: sine64 = -8'sd60;
        6'd38: sine64 = -8'sd71;
        6'd39: sine64 = -8'sd81;
        6'd40: sine64 = -8'sd90;
        6'd41: sine64 = -8'sd98;
        6'd42: sine64 = -8'sd106;
        6'd43: sine64 = -8'sd112;
        6'd44: sine64 = -8'sd117;
        6'd45: sine64 = -8'sd122;
        6'd46: sine64 = -8'sd125;
        6'd47: sine64 = -8'sd126;
        6'd48: sine64 = -8'sd127;
        6'd49: sine64 = -8'sd126;
        6'd50: sine64 = -8'sd125;
        6'd51: sine64 = -8'sd122;
        6'd52: sine64 = -8'sd117;
        6'd53: sine64 = -8'sd112;
        6'd54: sine64 = -8'sd106;
        6'd55: sine64 = -8'sd98;
        6'd56: sine64 = -8'sd90;
        6'd57: sine64 = -8'sd81;
        6'd58: sine64 = -8'sd71;
        6'd59: sine64 = -8'sd60;
        6'd60: sine64 = -8'sd49;
        6'd61: sine64 = -8'sd37;
        6'd62: sine64 = -8'sd25;
        6'd63: sine64 = -8'sd12;
        default: sine64 = 8'sd0;
      endcase
    end
  endfunction

  wire [7:0] carrier_phase = chroma_phase[31:24];
  wire signed [7:0] carrier_sin = sine64(carrier_phase[7:2]);
  wire signed [7:0] carrier_cos = sine64(carrier_phase[7:2] + 6'd16);

  // Signed 10x8 products implemented as shift/add networks.
  // This is because we want to be sure Vivado does not decide to "steal" a DSP from Mandel engines for trivial calcs.
  function signed [17:0] mul_s10_s8_shift;
    input signed [9:0] a;
    input signed [7:0] b;
    reg signed [17:0] a_ext;
    reg signed [17:0] accum;
    reg [7:0] b_mag;
    integer bit_i;
    begin
      a_ext = {{8{a[9]}}, a};
      b_mag = b[7] ? ((~b) + 8'd1) : b;
      accum = 18'sd0;
      for (bit_i = 0; bit_i < 8; bit_i = bit_i + 1) begin
        if (b_mag[bit_i])
          accum = accum + (a_ext <<< bit_i);
      end
      mul_s10_s8_shift = b[7] ? -accum : accum;
    end
  endfunction

  wire signed [17:0] u_product =
      mul_s10_s8_shift(palette_u, carrier_sin);
  wire signed [17:0] v_product =
      mul_s10_s8_shift(palette_v, carrier_cos);
  wire signed [18:0] u_product_ext = {u_product[17], u_product};
  wire signed [18:0] v_product_ext = {v_product[17], v_product};
  
  // PAL phase alternation: invert the V component on alternate lines.
  // Use the delayed parity because active chroma is selected from the
  // one-cycle-delayed framebuffer/pixel pipeline.
  wire signed [18:0] active_mix = line_odd_d1 ?
                                   (u_product_ext - v_product_ext) :
                                   (u_product_ext + v_product_ext);
  
  // Retain the previously calibrated active-chroma gain.  Chroma is bypassed
  // independently of the calibrated luma mapping.
  
  wire signed [18:0] active_scaled_raw = active_mix >>> 8;
  
  // 125 = 128 - 4 + 1; keep the calibrated chroma gain in LUT fabric.
  
  wire signed [28:0] active_scaled_ext =
      {{10{active_scaled_raw[18]}}, active_scaled_raw};
  wire signed [28:0] active_chroma_product =
      (active_scaled_ext <<< 7) -
      (active_scaled_ext <<< 2) + active_scaled_ext;
  
  // Divide by 256 with a shift. Divide the magnitude and restore the sign so negative values also truncate toward zero (as signed division does).
  // This changes the calibrated gain from 125/255 to 125/256 (about 0.39% lower) and removes the divide-by-255 correction adder.
  // Again, we don't want Vivado to "steal" DSP from Mandel engines. :)
  
  wire active_product_negative = active_chroma_product[28];
  wire [28:0] active_product_magnitude = active_product_negative ?
      ((~active_chroma_product) + 29'd1) : active_chroma_product;
  wire [18:0] active_div256_magnitude = active_product_magnitude >> 8;
  wire signed [18:0] active_scaled = active_product_negative ?
      -$signed(active_div256_magnitude) :
       $signed(active_div256_magnitude);
  wire signed [19:0] active_chroma_sum = 20'sd128 + active_scaled;
  wire [7:0] chroma_pattern =
      (active_chroma_sum < 0) ? 8'd0 :
      (active_chroma_sum > 20'sd255) ? 8'd255 :
                                      active_chroma_sum[7:0];

  // PAL burst phase alternates by 180 degrees around the nominal +/-135 degree burst reference.
  // Its existing amplitude is retained while the monochrome Luma range is calibrated.
  
  wire [7:0] burst_phase = line_odd ?
                           (carrier_phase + 8'd160) :
                           (carrier_phase + 8'd96);
  wire signed [7:0] burst_sine = sine64(burst_phase[7:2]);
  
  // 18 = 16 + 2; keep the short burst gain out of DSP48E1 as well.
  
  wire signed [15:0] burst_sine_ext = {{8{burst_sine[7]}}, burst_sine};
  wire signed [15:0] burst_prod = (burst_sine_ext <<< 4) +
                                  (burst_sine_ext <<< 1);
  wire signed [15:0] burst_scaled = burst_prod >>> 7;
  wire signed [16:0] burst_chroma_sum = 17'sd128 + burst_scaled;
  wire [7:0] chroma_burst = burst_chroma_sum[7:0];

  always @(posedge clk) begin
    image_active <= img_active_now;
    if (in_sync)
      luma <= 8'd0;
    else if (burst_active)
      luma <= BLANK_CODE;
    else if (img_active_d1)
      luma <= font_bit ? LUMA_MAX[7:0] : picture_luma;
    else
      luma <= BLANK_CODE;

  end

  // Chroma and burst use the same 13.5 MHz sample clock as the raster and DAC.
  always @(posedge clk) begin
    if (burst_active)
      chroma <= chroma_burst;
    else if (img_active_d1 && !font_bit)
      chroma <= chroma_pattern;
    else
      chroma <= CHROMA_ZERO;
  end
endmodule
