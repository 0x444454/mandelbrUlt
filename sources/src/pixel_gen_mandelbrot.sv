// One Mandelbrot engine.
// This will use 6 DSP48E1 slices.
// 20 instances use (6*20=120) DSP48E1 slices in the XC7A50T (i.e. all of them).
//
// Signed fixed-point format Q3.22 (as per ARM "Q notation"):
//   - cx_q, cy_q, zx, zy are signed Q(FRAC) values (default FRAC=22).
//   - The escape test compares |z|^2 against 4.0 using full precision Q(2*FRAC).
//
// Handshake:
//   - 'start' asserted for one cycle while busy=0 launches a new pixel.
//   - 'busy' stays high while iterating; done pulses for 1 cycle on completion.
//   - 'iter8' is the framebuffer palette index:
//             0 for points inside the set, otherwise the low-byte iteration count plus one.
//             0xff saturates instead of wrapping to zero.
//
// Artix-7 implementation note:
//   Each signed 25x25 product uses two DSP48E1 slices.
//   The escape-test sum is deliberately built from CARRY4 primitives so it remains in fabric and has a fast, predictable carry path.
//
(* use_dsp = "no", keep_hierarchy = "yes" *)
module add_u50_carry4 (
    input  wire [49:0] a,
    input  wire [49:0] b,
    output wire [50:0] sum
);
    // Zero extension is correct: both inputs are squares and therefore non-negative, even though their source multipliers are signed.
    wire [51:0] a_ext = {2'b00, a};
    wire [51:0] b_ext = {2'b00, b};
    wire [51:0] propagate = a_ext ^ b_ext;
    wire [51:0] sum_ext;
    wire [51:0] carry_bits;
    wire [13:0] carry_link;

    assign carry_link[0] = 1'b0;

    genvar carry_i;
    generate
        for (carry_i = 0; carry_i < 13; carry_i = carry_i + 1) begin : G_CARRY
            CARRY4 u_carry4 (
                .CI     (carry_link[carry_i]),
                .CYINIT (1'b0),
                .DI     (a_ext[carry_i*4 +: 4]),
                .S      (propagate[carry_i*4 +: 4]),
                .O      (sum_ext[carry_i*4 +: 4]),
                .CO     (carry_bits[carry_i*4 +: 4])
            );
            assign carry_link[carry_i+1] = carry_bits[carry_i*4+3];
        end
    endgenerate

    // The sum of two 50-bit values needs 51 bits.
    // The 52nd carry-chain bit is only padding for the final four-bit CARRY4 primitive.
    assign sum = sum_ext[50:0];
endmodule

module pixel_gen_mandelbrot #(
    parameter int FRAC = 22
)(
    input  logic                  clk,
    input  logic                  rst,

    input  logic                  start,
    input  logic signed [24:0]    cx_q,       // complex C real, Q(FRAC)
    input  logic signed [24:0]    cy_q,       // complex C imag, Q(FRAC)
    input  logic [11:0]           max_iters,  // runtime max iters (16..4095), latched per pixel

    output logic                  busy,
    output logic                  done,
    output logic [7:0]            iter8
);

    // Mandelbrot formula:
    // z(0) = 0.
    // z(n+1) = z(n)^2 + c.
    // ^^^ Iterate until |z|^2 > 4 (escape) or iter reaches max limit (max_it).

    logic signed [24:0] zx;
    logic signed [24:0] zy;
    logic signed [24:0] cx;
    logic signed [24:0] cy;

    logic [11:0] iter;
    logic [11:0] max_it;

    // A signed 25x25 multiply uses 2 DSP slices.
    // Preserve these three multiplier boundaries:
    //   3 products * 2 slices = 6 DSP slices per engine.

    (* use_dsp = "yes", keep = "true" *) logic signed [49:0] zx_zx_50;
    (* use_dsp = "yes", keep = "true" *) logic signed [49:0] zy_zy_50;
    (* use_dsp = "yes", keep = "true" *) logic signed [49:0] zx_zy_50;
    
    wire [50:0] mag2_full;

    logic signed [24:0] zx2;
    logic signed [24:0] zy2;
    logic signed [24:0] two_zxzy;

    logic signed [24:0] zx_next;
    logic signed [24:0] zy_next;
    
    // Full-precision Q(2*FRAC) escape threshold: |z|^2 > 4.0.

    localparam logic [50:0] ESCAPE_Q2 = (51'd4 << (2*FRAC));

    add_u50_carry4 u_mag2_add (
        .a   (zx_zx_50),
        .b   (zy_zy_50),
        .sum (mag2_full)
    );

    always_comb begin
        zx_zx_50 = $signed(zx) * $signed(zx);
        zy_zy_50 = $signed(zy) * $signed(zy);
        zx_zy_50 = $signed(zx) * $signed(zy);

        zx2 = $signed(zx_zx_50 >>> FRAC);
        zy2 = $signed(zy_zy_50 >>> FRAC);
        two_zxzy = $signed(zx_zy_50 >>> (FRAC-1)); // 2*zx*zy

        zx_next = (zx2 - zy2) + cx;
        zy_next = $signed(two_zxzy + cy);

    end

    always_ff @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            iter8 <= 8'd0;

            zx <= 25'sd0;
            zy <= 25'sd0;
            cx <= 25'sd0;
            cy <= 25'sd0;

            iter <= 12'd0;
            max_it <= 12'd16;
        end
        else begin
            done <= 1'b0;

            if (start && !busy) begin
                // Begin a new pixel using z0 = 0.
                busy <= 1'b1;
                cx <= cx_q;
                cy <= cy_q;
                // Latch the iteration limit so a control change cannot alter a pixel already in progress.
                // Enforce a defensive minimum of 16.
                max_it <= (max_iters < 12'd16) ? 12'd16 : max_iters;
                zx   <= 25'sd0;
                zy   <= 25'sd0;
                iter <= 12'd0;
            end
            else if (busy) begin
                if (mag2_full > ESCAPE_Q2) begin
                    // Escaped: nonzero values select palette colours.
                    busy <= 1'b0;
                    done <= 1'b1;
                    iter8 <= (&iter[7:0]) ? 8'hff : (iter[7:0] + 8'd1);
                end
                else if (iter == (max_it - 12'd1)) begin
                    // Did not escape: palette index zero is Mandelbrot black.
                    busy <= 1'b0;
                    done <= 1'b1;
                    iter8 <= 8'd0;
                end
                else begin
                    // z(n+1) = z(n)^2 + c.
                    zx <= zx_next;
                    zy <= zy_next;
                    iter <= iter + 12'd1;
                end
            end
        end
    end
endmodule
