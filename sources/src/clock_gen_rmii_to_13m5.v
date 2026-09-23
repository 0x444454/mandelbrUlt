module clock_gen_rmii_to_13m5 (
  input  wire clk_in,
  output wire clk_pix,
  output wire clk_calc,
  output wire locked
);

  // Generate the 13.5 MHz video clock and the 100 MHz Mandel calculation clock from the same 675 MHz MMCM VCO.
  wire clkfb_pix;
  wire clk_pix_mmcm;
  wire clk_calc_mmcm;

  MMCME2_BASE #(
    .BANDWIDTH("OPTIMIZED"),
    .CLKIN1_PERIOD(20.000),
    .DIVCLK_DIVIDE(2),
    .CLKFBOUT_MULT_F(27.000),
    .CLKFBOUT_PHASE(0.000),

    // 50 MHz input -> 675 MHz VCO.
    // CLKOUT0: 675 / 6.75 = 100 MHz Mandel calculation clock.
    .CLKOUT0_DIVIDE_F(6.750),
    .CLKOUT0_PHASE(0.000),
    .CLKOUT0_DUTY_CYCLE(0.500),

    // CLKOUT1: 675 / 50 = 13.5 MHz video clock.
    .CLKOUT1_DIVIDE(50),
    .CLKOUT1_PHASE(0.000),
    .CLKOUT1_DUTY_CYCLE(0.500),

    .STARTUP_WAIT("FALSE")
  ) u_mmcm_pix (
    .CLKIN1(clk_in),
    .CLKFBIN(clkfb_pix),
    .CLKFBOUT(clkfb_pix),
    .CLKOUT0(clk_calc_mmcm),
    .CLKOUT1(clk_pix_mmcm),
    .LOCKED(locked),
    .PWRDWN(1'b0),
    .RST(1'b0)
  );

  BUFG u_bufg_pix (.I(clk_pix_mmcm), .O(clk_pix));
  BUFG u_bufg_calc (.I(clk_calc_mmcm), .O(clk_calc));
endmodule
