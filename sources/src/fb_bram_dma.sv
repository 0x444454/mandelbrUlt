// Commits completed Mandelbrot scanlines from the two-line render buffer into the main framebuffer (also in BRAM for the C64U).
(* use_dsp = "no" *)
module fb_bram_dma #(
    parameter int FB_W = 352,
    parameter int FB_H = 256,
    parameter int FB_AW = $clog2(FB_W * FB_H)
)(
    input  logic clk,
    input  logic rst,

    output logic        rb_bank,
    output logic [9:0]  rb_addr,
    input  logic [7:0]  rb_data,

    input  logic        wb_full0,
    input logic        wb_full1,
    input logic [$clog2(FB_H)-1:0] wb_y0,
    input logic [$clog2(FB_H)-1:0] wb_y1,

    output logic        commit_take,
    output logic        commit_done,
    output logic        commit_bank,

    output logic        fb_we,
    output logic [FB_AW-1:0] fb_addr,
    output logic [7:0]  fb_data
);

    typedef enum logic [1:0] { ST_IDLE, ST_PRIME, ST_WRITE, ST_FETCH } state_t;
    state_t state;

    logic        wr_bank;
    logic [9:0]  wr_i;
    logic [FB_AW-1:0] wr_base;

    localparam int Y_W = $clog2(FB_H);

    function automatic [FB_AW-1:0] line_base(input logic [Y_W-1:0] y);
        logic [FB_AW-1:0] y_ext;
        begin
            // Current framebuffer width is 352 = 256 + 64 + 32.
            // We use shifts insted of mult to avoid Vivado allocating DSP resources for trivial calculations.
            y_ext = {{(FB_AW-Y_W){1'b0}}, y};
            line_base = (y_ext << 8) +
                        (y_ext << 6) +
                        (y_ext << 5);
        end
    endfunction

    logic have_commit;
    always_comb begin
        have_commit = wb_full0 | wb_full1;
    end

    // The render line buffer has a registered read port.
    // Once ST_WRITE is entered, rb_data is valid for rb_addr during the whole cycle.
    // We keep the framebuffer write bus combinational so the dual-port framebuffer sees that byte at the following clock edge.
    always_comb begin
        fb_we   = (state == ST_WRITE);
        fb_addr = wr_base + wr_i;
        fb_data = rb_data;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            // RESET.
            state        <= ST_IDLE;
            rb_bank      <= 1'b0;
            rb_addr      <= 10'd0;
            wr_bank      <= 1'b0;
            wr_i         <= 10'd0;
            wr_base      <= '0;
            commit_take  <= 1'b0;
            commit_done  <= 1'b0;
            commit_bank  <= 1'b0;
        end else begin
            // Normal op, state machine.
            commit_take <= 1'b0;
            commit_done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (have_commit) begin
                        if (wb_full0) begin
                            wr_bank <= 1'b0;
                            wr_base <= line_base(wb_y0);
                        end else begin
                            wr_bank <= 1'b1;
                            wr_base <= line_base(wb_y1);
                        end
                        wr_i        <= 10'd0;
                        rb_bank     <= wb_full0 ? 1'b0 : 1'b1;
                        rb_addr     <= 10'd0;
                        commit_bank <= wb_full0 ? 1'b0 : 1'b1;
                        commit_take <= 1'b1;
                        state       <= ST_PRIME;
                    end
                end

                ST_PRIME: begin
                    state <= ST_WRITE;
                end

                ST_WRITE: begin
                    if (wr_i == FB_W-1) begin
                        commit_done <= 1'b1;
                        commit_bank <= wr_bank;
                        state       <= ST_IDLE;
                    end else begin
                        // The write at this edge consumes the current rb_data.
                        // Request the next byte after the edge, then wait one cycle for the linebuf read port.
                        rb_addr  <= rb_addr + 10'd1;
                        state    <= ST_FETCH;
                    end
                end

                ST_FETCH: begin
                    // rb_data for the newly requested address is now valid after this edge.
                    // Expose it during the next write cycle and advance the destination index.
                    wr_i <= wr_i + 10'd1;
                    state <= ST_WRITE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
