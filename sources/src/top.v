// DDT's fixed-point Mandelbrot generator for the Commodore 64 Ultimate (XC7A50T).
// Should be easily portable to Commodore 77 (XC7A100T).
//
// Check Github page for more info:
//
//   https://github.com/0x444454/mandelbrUlt
//
// Use Xilinx Vivado to build. I use Vivado v2025.2.
//
// LICENSE: Creative Commons, CC BY
//          https://creativecommons.org/licenses/by/4.0/deed.en
//
// Revision history [authors in square brackets]:
//   2026-09-19: First implementation ported from "mandel_CmodA7", 100 MHz, 20 Mandel cores. Some timing warnings, but seems to work ok. [DDT]
//
(* use_dsp = "no" *)
module top (
  input  wire        RMII_REFCLK,
  input  wire [4:0]  KBJOY_1_JOY,
  input  wire [4:0]  KBJOY_2_JOY,
  input  wire        KBJOY_RESTORE,
  output wire        CIA_PWR_EN,
  output wire        CIA_BUFFER_EN,
  output wire        LED_BOARDn,
  output wire        LED_CASE1n,
  output wire        LED_CASE2n,
  output wire        LED_CASE3n,
  output wire        CLOCK_C64_SYNTH,
  output wire        AVID_CLK,
  output wire        AVID_SYNCn,
  output wire        AVID_FB,
  output wire [9:2]  AVID_R,
  output wire [9:2]  AVID_G,
  output wire [9:2]  AVID_B
);

  // Mandelbrot logical resolution is 352x256.
  // The 704-sample PAL raster repeats each framebuffer pixel twice horizontally (square logical pixels).
  localparam integer FB_W = 352;
  localparam integer FB_H = 256;
  localparam integer FB_AW = $clog2(FB_W * FB_H);
  
  // Mandel engines clock.
  // Some timing warnings, but 100 MHz seems to work ok.
  localparam integer CLK_CALC_HZ = 100_000_000;
  
  // Number of mandel engines (each engine uses 6 DSP48E1 slices):
  // Set this to:
  //   -  15 for XC7A35T   (90 DSP slices).
  //   -  20 for XC7A50T  (120 DSP slices). <--- Commodore 64 Ultimate.
  //   -  30 for XC7A75T  (180 DSP slices). 
  //   -  40 for XC7A100T (240 DSP slices). <--- Commodore 77.
  //   - 123 for XC7A200T (740 DSP slices). <--- Mega65.
  localparam integer MANDEL_CORES = 20;

  assign CLOCK_C64_SYNTH = 1'b1;

  // Enable the C64U CIA/joystick power rail and its interface buffers.
  // Both board-level enables are active-high.
  assign CIA_PWR_EN    = 1'b1;
  assign CIA_BUFFER_EN = 1'b1;

  wire rmii_i;
  wire clk_rmii;
  IBUFG u_ibufg_rmii (.I(RMII_REFCLK), .O(rmii_i));
  BUFG  u_bufg_rmii  (.I(rmii_i), .O(clk_rmii));

  wire clk_pix;
  wire clk_calc;
  wire clk_locked;
  clock_gen_rmii_to_13m5 u_clk (
    .clk_in(clk_rmii),
    .clk_pix(clk_pix),
    .clk_calc(clk_calc),
    .locked(clk_locked)
  );

  // Renderer-only power-on reset (video out stays intact).
  reg [22:0] por_cnt = 23'd0;
  reg        por_done = 1'b0;
  always @(posedge clk_calc) begin
    if (!clk_locked) begin
      por_cnt  <= 23'd0;
      por_done <= 1'b0;
    end else if (!por_done) begin
      por_cnt <= por_cnt + 23'd1;
      if (&por_cnt)
        por_done <= 1'b1;
    end
  end

  wire rst_async = !por_done;
  reg [1:0] rst_calc_sync = 2'b11;
  always @(posedge clk_calc or posedge rst_async) begin
    if (rst_async) rst_calc_sync <= 2'b11;
    else rst_calc_sync <= {rst_calc_sync[0], 1'b0};
  end
  wire rst_calc = rst_calc_sync[1];

  // The THS8136 latches RGB and BLANK on the rising edge of AVID_CLK.
  assign AVID_CLK = ~clk_pix;

  wire        csync_n;
  wire        active;
  wire        in_sync;
  wire        burst_active;
  wire        line_odd;
  wire [9:0]  x;
  wire [8:0]  y;
  wire        frame_start;
  video_timing u_timing (
    .clk(clk_pix), .csync_n(csync_n), .in_sync(in_sync), .active(active),
    .burst_active(burst_active), .line_odd(line_odd), .x(x), .y(y),
    .frame_start(frame_start)
  );

  // C64U joystick port 2 is active-low with XDC pull-ups.
  // Fire is the action input and RESTORE resets the zoom (TODO: RESTORE does not seem to be working).
  wire move_up, move_down, move_left, move_right, move_tick;
  wire zoom_in_pulse, zoom_out_pulse;
  wire iters_dec_pulse, iters_inc_pulse, zoom_reset_pulse;
  joystick_buttons #(
    .CLK_HZ(CLK_CALC_HZ), .SAMPLE_HZ(1000), .MOVE_HZ(512)
  ) u_joy (
    .clk(clk_calc), .rst(rst_calc),
    .joy_up_n(KBJOY_2_JOY[0]), .joy_down_n(KBJOY_2_JOY[1]),
    .joy_left_n(KBJOY_2_JOY[2]), .joy_right_n(KBJOY_2_JOY[3]),
    .joy_set_n(KBJOY_2_JOY[4]), .joy_rst_n(KBJOY_RESTORE),
    .move_up(move_up), .move_down(move_down), .move_left(move_left),
    .move_right(move_right), .move_tick(move_tick),
    .zoom_in_pulse(zoom_in_pulse), .zoom_out_pulse(zoom_out_pulse),
    .iters_dec_pulse(iters_dec_pulse), .iters_inc_pulse(iters_inc_pulse),
    .zoom_reset_pulse(zoom_reset_pulse)
  );


  // Counters for "splash screen" and "fire hold to cycle palette" (in video frames).
  localparam [8:0] SPLASH_FRAMES = 9'd501;
  localparam [6:0] PALETTE_HOLD_FRAMES = 7'd100;

  // Synchronize the raw port-2 joystick contacts into the known-good video clock domain.
  // They are sampled once per frame.
  reg [4:0] joy_n_pix_ff1 = 5'h1f;
  reg [4:0] joy_n_pix_ff2 = 5'h1f;

  always @(posedge clk_pix) begin
    joy_n_pix_ff1 <= KBJOY_2_JOY;
    joy_n_pix_ff2 <= joy_n_pix_ff1;
  end

  wire joy_fire_only_pix = !joy_n_pix_ff2[4] && (&joy_n_pix_ff2[3:0]);

  reg [8:0] splash_frame_count = 9'd0;
  reg [6:0] palette_hold_frame_count = 7'd0;
  reg       startup_text_enable = 1'b1;
  reg       palette_cycle_qualified = 1'b0;

  // Stop cycling palette if fire released or any direction pressed.

  wire palette_cycle_enable = palette_cycle_qualified && joy_fire_only_pix;

  always @(posedge clk_pix) begin
    // Handle palette cycle.
    if (!joy_fire_only_pix) begin
      palette_hold_frame_count <= 7'd0;
      palette_cycle_qualified <= 1'b0;
    end else if (frame_start && !palette_cycle_qualified) begin
      if (palette_hold_frame_count == (PALETTE_HOLD_FRAMES - 7'd1)) begin
        palette_hold_frame_count <= PALETTE_HOLD_FRAMES;
        palette_cycle_qualified <= 1'b1;
      end else begin
        palette_hold_frame_count <= palette_hold_frame_count + 7'd1;
      end
    end

    if (frame_start) begin
      // Handle splash screen delay.
      if (startup_text_enable) begin
        if (splash_frame_count == (SPLASH_FRAMES - 9'd1))
          startup_text_enable <= 1'b0;
        else
          splash_frame_count <= splash_frame_count + 9'd1;
      end
    end
  end

  localparam integer FRAC = 22;
  localparam integer signed SCALE_INIT_INT = (3 <<< FRAC) / FB_W;
  localparam signed [24:0] SCALE_INIT = SCALE_INIT_INT;
  reg signed [24:0] center_x_q;
  reg signed [24:0] center_y_q;
  reg signed [24:0] scale_q;
  reg [11:0] max_iters;

  always @(posedge clk_calc) begin
    if (rst_calc) begin
      center_x_q <= -25'sd2097152;
      center_y_q <= 25'sd0;
      scale_q    <= SCALE_INIT;
      max_iters  <= 12'd128;
    end else begin
      if (move_tick) begin
        if (move_left)  center_x_q <= center_x_q - scale_q;
        if (move_right) center_x_q <= center_x_q + scale_q;
        if (move_up)    center_y_q <= center_y_q - scale_q;
        if (move_down)  center_y_q <= center_y_q + scale_q;
      end
      if (zoom_reset_pulse) scale_q <= SCALE_INIT;
      if (zoom_in_pulse) begin
        if ((scale_q >>> 1) == 0) scale_q <= 25'sd1;
        else scale_q <= scale_q >>> 1;
      end
      if (zoom_out_pulse) scale_q <= scale_q <<< 1;
      if (iters_dec_pulse) begin
        if (max_iters <= 12'd16) max_iters <= 12'd16;
        else max_iters <= max_iters - 12'd16;
      end
      if (iters_inc_pulse) begin
        if (max_iters >= 12'd4079) max_iters <= 12'd4095;
        else max_iters <= max_iters + 12'd16;
      end
    end
  end

  wire pan_step = move_tick & (move_up | move_down | move_left | move_right);
  wire render_restart = pan_step | zoom_in_pulse | zoom_out_pulse |
                        iters_inc_pulse | iters_dec_pulse | zoom_reset_pulse;

  wire        wb_we, wb_bank;
  wire [9:0]  wb_addr;
  wire [7:0]  wb_data;
  wire        wb_full0, wb_full1;
  wire [$clog2(FB_H)-1:0] wb_y0, wb_y1;
  wire        commit_take, commit_done, commit_bank;
  wire        render_busy;

  fb_scanline_writer #(.NCORES(MANDEL_CORES), .FB_W(FB_W), .FB_H(FB_H), .FRAC(FRAC))
  u_writer (
    .clk(clk_calc), .rst(rst_calc),
    .render_busy(render_busy),
    .wb_we(wb_we), .wb_bank(wb_bank), .wb_addr(wb_addr), .wb_data(wb_data),
    .wb_full0(wb_full0), .wb_full1(wb_full1), .wb_y0(wb_y0), .wb_y1(wb_y1),
    .commit_take(commit_take), .commit_done(commit_done),
    .commit_bank(commit_bank),
    .center_x_q(center_x_q), .center_y_q(center_y_q), .scale_q(scale_q),
    .restart(render_restart), .iters_q(max_iters)
  );

  wire        rb_bank_rd;
  wire [9:0]  rb_addr_rd;
  wire [7:0]  rb_data_rd;
  linebuf_iter8 u_renderbuf (
    .clk_wr(clk_calc), .we(wb_we), .bank_wr(wb_bank), .addr_wr(wb_addr),
    .data_wr(wb_data), .clk_rd(clk_calc), .bank_rd(rb_bank_rd),
    .addr_rd(rb_addr_rd), .data_rd(rb_data_rd)
  );

  wire fb_we;
  wire [FB_AW-1:0] fb_wr_addr;
  wire [7:0] fb_wr_data;
  fb_bram_dma #(.FB_W(FB_W), .FB_H(FB_H), .FB_AW(FB_AW)) u_fb_dma (
    .clk(clk_calc), .rst(rst_calc), .rb_bank(rb_bank_rd), .rb_addr(rb_addr_rd),
    .rb_data(rb_data_rd), .wb_full0(wb_full0), .wb_full1(wb_full1),
    .wb_y0(wb_y0), .wb_y1(wb_y1), .commit_take(commit_take),
    .commit_done(commit_done), .commit_bank(commit_bank), .fb_we(fb_we),
    .fb_addr(fb_wr_addr), .fb_data(fb_wr_data)
  );

  // 352x256 framebuffer centered vertically in the 704x288 active raster.
  // Each logical framebuffer pixel occupies two horizontal PAL samples.
  wire fb_window = active && (y >= 9'd16) && (y < 9'd272);
  wire [8:0] fb_y = y - 9'd16;
  wire [8:0] fb_x = x[9:1];
  wire [16:0] fb_line_base = ({8'd0, fb_y} << 8) +
                              ({8'd0, fb_y} << 6) +
                              ({8'd0, fb_y} << 5);
  wire [16:0] fb_rd_addr = fb_line_base + {8'd0, fb_x};
  wire [7:0] fb_iter8;
  framebuffer_bram #(.FB_W(FB_W), .FB_H(FB_H), .ADDR_W(FB_AW)) u_framebuffer (
    .clk_wr(clk_calc), .wr_en(fb_we), .wr_addr(fb_wr_addr), .wr_data(fb_wr_data),
    .clk_rd(clk_pix), .rd_en(fb_window),
    .rd_addr(fb_window ? fb_rd_addr : {FB_AW{1'b0}}), .rd_data(fb_iter8)
  );

  wire [7:0] video_luma, video_chroma;
  wire image_active;
  mandel_video_pattern u_pattern (
    .clk(clk_pix), .frame_start(frame_start), .active(active),
    .in_sync(in_sync), .burst_active(burst_active), .line_odd(line_odd),
    .x(x), .y(y), .fb_iter8(fb_iter8),
    .text_enable(startup_text_enable),
    .palette_cycle_enable(palette_cycle_enable), .luma(video_luma),
    .chroma(video_chroma), .image_active(image_active)
  );

  reg sync_q = 1'b1;
  always @(posedge clk_pix) begin
    sync_q <= csync_n;
  end
  assign AVID_SYNCn = sync_q;

  // Keep the DAC blanked outside the picture window.
  assign AVID_FB = image_active;

  // Handle Composite video at 13.5 MHz.
  wire signed [10:0] composite_sum =
      $signed({3'b000, video_luma}) +
      ($signed({3'b000, video_chroma}) - 11'sd128);
  wire [7:0] video_composite =
      (composite_sum < 11'sd0)   ? 8'h00 :
      (composite_sum > 11'sd255) ? 8'hFF : composite_sum[7:0];

  reg [7:0] avid_r_q = 8'd0;
  reg [7:0] avid_g_q = 8'd0;
  reg [7:0] avid_b_q = 8'd128;
  always @(posedge clk_pix) begin
    avid_r_q <= video_composite;        // AVID_R: Composite video.
    avid_g_q <= video_luma;             // AVID_G: Luma.
    avid_b_q <= video_chroma;           // AVID_B: Chroma.
  end
  assign AVID_R = avid_r_q;
  assign AVID_G = avid_g_q;
  assign AVID_B = avid_b_q;

  // TODO: How do we drive the case LED ?
  assign LED_CASE1n = 1'b1;
  assign LED_CASE2n = 1'b1;
  assign LED_CASE3n = 1'b1;

  // The motherboard diagnostic LED is active-low:
  // - LED ON  = Calculating.
  // - LED OFF = Idle.
  assign LED_BOARDn = ~render_busy;
endmodule
