// Out-of-order Mandelbrot renderer and scanline scheduler.
//
// Summary:
//   - Issues pixels coordinates in scanline order to free Mandel engines.
//   - Engines run in parallel and can complete out-of-order.
//   - Retires results into a 2-line BRAM write buffer (iter8).
//   - Completed lines are handed to the BRAM framebuffer commit DMA.
//
// Coordinate setup includes the constant scale_q * 176 operation written as shifts and adds to prevent Vivado to use DSP resources.
//
(* use_dsp = "no" *)
module fb_scanline_writer #(
    // The video path performs palette lookup during scanout, so the framebuffer
    // stores only the eight-bit iteration index. At most two lines are in
    // flight; issue stalls when both line-buffer banks await BRAM commit.
    parameter int NCORES = 20,      // Number of engines. This value will be overwritten by top.v using the actual number of cores used.
    parameter int FB_W   = 960,
    parameter int FB_H   = 544,
    parameter int FRAC   = 22
)(
    input  logic                    clk,
    input  logic                    rst,

    // High from render initialization through completion of the final pixel.
    // This is exported for status indication; it does not control scheduling.
    output logic                    render_busy,

    // Write buffer port (iter8). One pixel retired per cycle max.
    output logic                    wb_we,
    output logic                    wb_bank,
    output logic [9:0]              wb_addr,
    output logic [7:0]              wb_data,

    // Per-bank status for the framebuffer commit DMA.
    output logic                    wb_full0,
    output logic                    wb_full1,
    output logic [$clog2(FB_H)-1:0] wb_y0,
    output logic [$clog2(FB_H)-1:0] wb_y1,

    // Commit handshake from the BRAM framebuffer DMA.
    input  logic                    commit_take, // DMA is starting a commit of wb_bank.
    input  logic                    commit_done, // DMA finished commit of wb_bank and the bank can be reused.
    input  logic                    commit_bank, // Bank to commit [0 or 1].

    input  logic signed [24:0]      center_x_q,
    input  logic signed [24:0]      center_y_q,
    input  logic signed [24:0]      scale_q,
    input  logic                    restart,
    input  logic [11:0]             iters_q
);

    localparam int X_W       = $clog2(FB_W);
    localparam int Y_W       = $clog2(FB_H);
    localparam int Y_COUNT_W = $clog2(FB_H + 1);
    localparam int DONE_W    = $clog2(FB_W + 1);

    // -------------------------------------------------------------------------
    // Multiply scale by (FB_W/2) or (FB_H/2) to find the upper-left corner.
    // -------------------------------------------------------------------------
    function automatic logic signed [24:0] mul_half_w(input logic signed [24:0] s);
        // HALF_W = 176 = 128 + 32 + 16.
        mul_half_w = (s <<< 7) + (s <<< 5) + (s <<< 4);
    endfunction

    function automatic logic signed [24:0] mul_half_h(input logic signed [24:0] s);
        // HALF_H = 128.
        mul_half_h = s <<< 7;
    endfunction

    // -------------------------------------------------------------------------
    // Bank tracking.
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        B_FREE   = 2'd0,
        B_FILL   = 2'd1,
        B_FULL   = 2'd2,
        B_COMMIT = 2'd3
    } bank_state_t;

    bank_state_t bank_state [2];
    logic [Y_W-1:0]    bank_y    [2];
    logic [DONE_W-1:0] bank_done [2];

    // Expose status.
    assign wb_full0 = (bank_state[0] == B_FULL);
    assign wb_full1 = (bank_state[1] == B_FULL);
    assign wb_y0    = bank_y[0];
    assign wb_y1    = bank_y[1];

    // -------------------------------------------------------------------------
    // Render control / coordinate generator (scanline order)
    // -------------------------------------------------------------------------
    logic need_render;

    logic [X_W-1:0]       issue_x;
    logic [Y_COUNT_W-1:0] issue_y;

    logic signed [24:0]   ax_q;
    logic signed [24:0]   cur_cx_q;
    logic signed [24:0]   cur_cy_q;

    // The 352x256 logical FB is displayed as 704 PAL samples (each FB pixel doubled horizontally).
    // This should produce square pixels in PAL.
    wire signed [24:0] half_step_q = scale_q >>> 1;

    // -------------------------------------------------------------------------
    // Mandelbrot cores + handling logic
    // -------------------------------------------------------------------------
    logic [NCORES-1:0] core_start;
    logic [NCORES-1:0] core_launched;
    logic [NCORES-1:0] core_busy;
    logic [NCORES-1:0] core_done;

    logic signed [24:0] core_cx_q   [NCORES];
    logic signed [24:0] core_cy_q   [NCORES];
    logic [7:0]         core_iter8  [NCORES];

    // Render generation tag (prevents committing stale pixels after a restart).
    logic [1:0]         gen;
    logic [1:0]         core_gen [NCORES];

    // Request metadata (where to store the result).
    logic [X_W-1:0]     core_req_x   [NCORES];
    logic               core_req_bank[NCORES];

    // Completed results latch.
    logic [NCORES-1:0]  res_valid;
    logic [X_W-1:0]     res_x    [NCORES];
    logic               res_bank [NCORES];
    logic [7:0]         res_iter8[NCORES];

    // Instantiate Mandel engines (cores).
    genvar gi;
    generate
        for (gi = 0; gi < NCORES; gi = gi + 1) begin : G_PX
            pixel_gen_mandelbrot #(
                .FRAC(FRAC)
            ) u_px (
                .clk(clk),
                .rst(rst),

                .start(core_start[gi]),
                .cx_q(core_cx_q[gi]),
                .cy_q(core_cy_q[gi]),
                .max_iters(iters_q),

                .busy(core_busy[gi]),
                .done(core_done[gi]),
                .iter8(core_iter8[gi])
            );
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Pick one completed result to retire (lowest index wins).
    // -------------------------------------------------------------------------
    logic                      cand_any;
    logic [$clog2(NCORES)-1:0] cand_sel;

    integer k;
    always_comb begin
        cand_any = 1'b0;
        cand_sel = '0;
        for (k = 0; k < NCORES; k = k + 1) begin
            if (!cand_any && res_valid[k]) begin
                cand_any = 1'b1;
                cand_sel = k[$clog2(NCORES)-1:0];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Main control.
    // -------------------------------------------------------------------------
    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            // Reset cores.
            render_busy <= 1'b0;
            need_render <= 1'b1;

            issue_x <= '0;
            issue_y <= '0;

            ax_q     <= 25'sd0;
            cur_cx_q <= 25'sd0;
            cur_cy_q <= 25'sd0;

            core_start    <= '0;
            core_launched <= '0;

            gen <= 2'd0;

            wb_we   <= 1'b0;
            wb_bank <= 1'b0;
            wb_addr <= 10'd0;
            wb_data <= 8'd0;

            bank_state[0] <= B_FREE;
            bank_state[1] <= B_FREE;
            bank_y[0]     <= '0;
            bank_y[1]     <= '0;
            bank_done[0]  <= '0;
            bank_done[1]  <= '0;

            for (i = 0; i < NCORES; i = i + 1) begin
                core_cx_q[i]      <= 25'sd0;
                core_cy_q[i]      <= 25'sd0;
                core_req_x[i]     <= '0;
                core_req_bank[i]  <= 1'b0;
                res_valid[i]      <= 1'b0;
                res_x[i]          <= '0;
                res_bank[i]       <= 1'b0;
                res_iter8[i]      <= 8'd0;
                core_gen[i]       <= 2'd0;
            end
        end else begin
            // Default.
            core_start <= '0;
            wb_we      <= 1'b0;

            // The commit DMA claims a complete line with commit_take and frees its bank with commit_done after writing it to framebuffer BRAM.

            if (commit_take) begin
                bank_state[commit_bank] <= B_COMMIT;
            end
            if (commit_done) begin
                bank_state[commit_bank] <= B_FREE;
                bank_y[commit_bank]     <= '0;
                bank_done[commit_bank]  <= '0;
            end

            // core_launched is a 1-cycle helper that prevents double-launching a core (race-condition) before its busy flag is observed.
            // Once busy goes high we can clear launched.

            for (i = 0; i < NCORES; i = i + 1) begin
                if (core_launched[i] && core_busy[i]) begin
                    core_launched[i] <= 1'b0;
                end
            end

            // Latch completed results.
            //
            // Each core has request metadata captured at launch time (x, y, bank).
            // When done pulses, capture the result into a per-core holding register (res_*). 
            // A later stage retires at most one res_* per clk into WB.
            //
            // gen/core_gen marks the generated image, so we can discard pixels belonging to older images.
            // When we need to restart rendering, we bump gen and ignore any late completions from the previous images.

            for (i = 0; i < NCORES; i = i + 1) begin
                if (core_done[i] && (core_gen[i] == gen)) begin
                    res_valid[i] <= 1'b1;
                    res_x[i]     <= core_req_x[i];
                    res_bank[i]  <= core_req_bank[i];
                    res_iter8[i] <= core_iter8[i];
                end
            end

            // Retire at most one completed result into the write buffer per cycle.
            // Retire policy:
            // - At most one pixel per clk.
            // - We pick the lowest-index core that has res_valid=1 and write its iter8 value into the BRAM write buffer at address {bank, x}.

            if (cand_any) begin
                wb_we   <= 1'b1;
                wb_bank <= res_bank[cand_sel];
                wb_addr <= {{(10-X_W){1'b0}}, res_x[cand_sel]};
                wb_data <= res_iter8[cand_sel];

                // Mark retired.
                res_valid[cand_sel] <= 1'b0;

                // Update per-bank completion count.
                // bank_done[] counts how many pixels have been retired for that bank.
                // When it reaches FB_W, the bank becomes FULL and waits for DMA commit.

                if (bank_state[res_bank[cand_sel]] == B_FILL) begin
                    if (bank_done[res_bank[cand_sel]] == (FB_W - 1)) begin
                        bank_done[res_bank[cand_sel]]  <= bank_done[res_bank[cand_sel]] + 1'b1;
                        bank_state[res_bank[cand_sel]] <= B_FULL;
                    end else begin
                        bank_done[res_bank[cand_sel]] <= bank_done[res_bank[cand_sel]] + 1'b1;
                    end
                end
            end

            // Start a new render if parameters changed or user action requested.
            if (restart) begin
                // Restart render.
                need_render <= 1'b1;
                render_busy <= 1'b0;

                gen <= gen + 2'd1;

                // Flush in-flight work/results (cores may still be running; we'll ignore mismatched gen).
                for (i = 0; i < NCORES; i = i + 1) begin
                    res_valid[i]      <= 1'b0;
                    core_launched[i]  <= 1'b0;
                end

                // Reset banks state.
                bank_state[0] <= B_FREE;
                bank_state[1] <= B_FREE;
                bank_done[0]  <= '0;
                bank_done[1]  <= '0;
                bank_y[0]     <= '0;
                bank_y[1]     <= '0;
            end

            // (Re)initialize render if needed and no render is active.
            if (need_render && !render_busy) begin
                // Offset by half a sample after subtracting half the full
                // span. This places center_x_q/center_y_q exactly between
                // the two middle pixels of the even-sized framebuffer.
                ax_q <= center_x_q - mul_half_w(scale_q) +
                        half_step_q;

                cur_cx_q <= center_x_q - mul_half_w(scale_q) +
                            half_step_q;
                cur_cy_q <= center_y_q - mul_half_h(scale_q) +
                            half_step_q;

                issue_x <= '0;
                issue_y <= '0;

                render_busy <= 1'b1;
                need_render <= 1'b0;
            end

            // Schedule at most 1 new pixel per cycle.
            if (render_busy) begin
                // Allocate a bank for the current issue_y, if needed.
                // NOTE: All block-scoped declarations must appear before any statements in this scope (Vivado is strict about this).
                logic have_bank;
                logic bank_sel;
                logic have_free;
                logic [$clog2(NCORES)-1:0] free_idx;

                have_bank = 1'b0;
                bank_sel  = 1'b0;
                have_free = 1'b0;
                free_idx  = '0;

                if (issue_y < FB_H) begin
                    if (bank_state[0] != B_FREE && {1'b0, bank_y[0]} == issue_y) begin
                        have_bank     = 1'b1;
                        bank_sel      = 1'b0;
                    end else if (bank_state[1] != B_FREE && {1'b0, bank_y[1]} == issue_y) begin
                        have_bank     = 1'b1;
                        bank_sel      = 1'b1;
                    end else begin
                        // Need a new bank for this line. Prefer bank0.
                        if (bank_state[0] == B_FREE) begin
                            bank_state[0] <= B_FILL;
                            bank_y[0]     <= issue_y[Y_W-1:0];
                            bank_done[0]  <= '0;
                            have_bank     = 1'b1;
                            bank_sel      = 1'b0;
                        end else if (bank_state[1] == B_FREE) begin
                            bank_state[1] <= B_FILL;
                            bank_y[1]     <= issue_y[Y_W-1:0];
                            bank_done[1]  <= '0;
                            have_bank     = 1'b1;
                            bank_sel      = 1'b1;
                        end
                    end
                end

                // Find first free Mandel engine (core).
                for (i = 0; i < NCORES; i = i + 1) begin
                    if (!have_free && (!core_busy[i]) && (!core_launched[i]) && (!res_valid[i]) && (!core_done[i])) begin
                        have_free = 1'b1;
                        free_idx  = i[$clog2(NCORES)-1:0];
                    end
                end

                // Launch one pixel if we still have work left and a bank is available.
                if (have_bank && have_free && (issue_y < FB_H)) begin
                    core_start[free_idx]    <= 1'b1;
                    core_launched[free_idx] <= 1'b1;
                    core_gen[free_idx]      <= gen;

                    core_cx_q[free_idx]     <= cur_cx_q;
                    core_cy_q[free_idx]     <= cur_cy_q;
                    core_req_x[free_idx]    <= issue_x;
                    core_req_bank[free_idx] <= bank_sel;

                    // Advance to next pixel in scanline order.
                    if (issue_x == (FB_W - 1)) begin
                        issue_x  <= '0;
                        issue_y  <= issue_y + 1'b1;
                        cur_cx_q <= ax_q;
                        cur_cy_q <= cur_cy_q + $signed(scale_q);
                    end else begin
                        issue_x  <= issue_x + 1'b1;
                        cur_cx_q <= cur_cx_q + $signed(scale_q);
                    end
                end

                // After issuing the last pixel, wait for every core and result slot to drain before clearing the busy status.
                if (issue_y >= FB_H) begin
                    logic any_active;
                    any_active = (|core_busy) | (|core_launched) | (|res_valid);
                    if (!any_active) begin
                        render_busy <= 1'b0; // Frame calculation completed.
                    end
                end
            end
        end
    end

endmodule
