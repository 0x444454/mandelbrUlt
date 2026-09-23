// Dual-port 8-bit Mandelbrot framebuffer.
//
// Port A is written by the calculation/commit clock.
// Port B is read by the 13.5 MHz video clock and has one registered read cycle of latency.
module framebuffer_bram #(
    parameter int FB_W = 352,
    parameter int FB_H = 256,
    parameter int ADDR_W = $clog2(FB_W * FB_H)
)(
    input  logic             clk_wr,
    input  logic             wr_en,
    input  logic [ADDR_W-1:0] wr_addr,
    input  logic [7:0]       wr_data,

    input  logic             clk_rd,
    input  logic             rd_en,
    input  logic [ADDR_W-1:0] rd_addr,
    output logic [7:0]       rd_data
);
    logic [7:0] doutb;

    xpm_memory_tdpram #(
        .ADDR_WIDTH_A(ADDR_W),
        .ADDR_WIDTH_B(ADDR_W),
        .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(8),
        .BYTE_WRITE_WIDTH_B(8),
        .CASCADE_HEIGHT(0),
        .CLOCKING_MODE("independent_clock"),
        .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"),
        .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(FB_W * FB_H * 8),
        .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_A(8),
        .READ_DATA_WIDTH_B(8),
        .READ_LATENCY_A(1),
        .READ_LATENCY_B(1),
        .READ_RESET_VALUE_A("0"),
        .READ_RESET_VALUE_B("0"),
        .RST_MODE_A("SYNC"),
        .RST_MODE_B("SYNC"),
        .SIM_ASSERT_CHK(0),
        .USE_EMBEDDED_CONSTRAINT(0),
        .USE_MEM_INIT(0),
        .WAKEUP_TIME("disable_sleep"),
        .WRITE_DATA_WIDTH_A(8),
        .WRITE_DATA_WIDTH_B(8),
        .WRITE_MODE_A("write_first"),
        .WRITE_MODE_B("read_first")
    ) u_fb (
        .clka   (clk_wr),
        .ena    (1'b1),
        .wea    (wr_en),
        .addra  (wr_addr),
        .dina   (wr_data),
        .douta  (),
        .regcea (1'b1),
        .rsta   (1'b0),

        .clkb   (clk_rd),
        .enb    (rd_en),
        .web    (1'b0),
        .addrb  (rd_addr),
        .dinb   (8'd0),
        .doutb  (doutb),
        .regceb (1'b1),
        .rstb   (1'b0),

        .sleep  (1'b0),
        .injectsbiterra(1'b0),
        .injectdbiterra(1'b0),
        .injectsbiterrb(1'b0),
        .injectdbiterrb(1'b0),
        .sbiterra(),
        .dbiterra(),
        .sbiterrb(),
        .dbiterrb()
    );

    assign rd_data = doutb;
endmodule
