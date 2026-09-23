// C64U joystick (port 2) controls.
// All six active-low contacts share one synchronizer/debounce time base instead of instantiating a timer per input.
//
(* use_dsp = "no" *)
module joystick_buttons #(
    parameter int CLK_HZ    = 100_000_000,   // NOTE: This will be overwritten by top.v using CLK_CALC_HZ.
    parameter int SAMPLE_HZ = 1000,
    parameter int MOVE_HZ   = 512,
    parameter int ITERS_HZ  = 128
)(
    // Inputs.
    input  logic clk,
    input  logic rst,
    input  logic joy_up_n,
    input  logic joy_down_n,
    input  logic joy_left_n,
    input  logic joy_right_n,
    input  logic joy_set_n,
    input  logic joy_rst_n,
    
    // Outputs.
    output logic move_up,
    output logic move_down,
    output logic move_left,
    output logic move_right,
    output logic move_tick,
    output logic zoom_in_pulse,
    output logic zoom_out_pulse,
    output logic iters_dec_pulse,
    output logic iters_inc_pulse,
    output logic zoom_reset_pulse
);

    localparam int SAMPLE_DIV = CLK_HZ / SAMPLE_HZ;
    localparam int MOVE_DIV   = CLK_HZ / MOVE_HZ;
    localparam int ITERS_DIV  = CLK_HZ / ITERS_HZ;

    // Bit order: {RESTORE, FIRE, RIGHT, LEFT, DOWN, UP}.
    wire [5:0] joy_n = {joy_rst_n, joy_set_n, joy_right_n,
                        joy_left_n, joy_down_n, joy_up_n};
    logic [5:0] joy_n_ff1 = 6'h3f;
    logic [5:0] joy_n_ff2 = 6'h3f;

    logic [$clog2(SAMPLE_DIV)-1:0] sample_count;
    logic [$clog2(MOVE_DIV)-1:0]   move_count;
    logic [$clog2(ITERS_DIV)-1:0]  iters_count;
    logic sample_tick;
    logic iters_tick;

    logic [7:0] hist_up;
    logic [7:0] hist_down;
    logic [7:0] hist_left;
    logic [7:0] hist_right;
    logic [7:0] hist_fire;
    logic [7:0] hist_restore;
    logic [5:0] pressed;
    logic [5:0] pressed_d;

    wire [5:0] pressed_pulse = pressed & ~pressed_d;
    wire up      = pressed[0];
    wire down    = pressed[1];
    wire left    = pressed[2];
    wire right   = pressed[3];
    wire fire    = pressed[4];

    always_ff @(posedge clk) begin
        if (rst) begin
            joy_n_ff1 <= 6'h3f;
            joy_n_ff2 <= 6'h3f;
        end else begin
            joy_n_ff1 <= joy_n;
            joy_n_ff2 <= joy_n_ff1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            sample_count <= '0;
            sample_tick  <= 1'b0;
            move_count   <= '0;
            move_tick    <= 1'b0;
            iters_count  <= '0;
            iters_tick   <= 1'b0;
        end else begin
            sample_tick <= 1'b0;
            move_tick   <= 1'b0;
            iters_tick  <= 1'b0;

            if (sample_count == SAMPLE_DIV-1) begin
                sample_count <= '0;
                sample_tick  <= 1'b1;
            end else begin
                sample_count <= sample_count + 1'b1;
            end

            if (move_count == MOVE_DIV-1) begin
                move_count <= '0;
                move_tick  <= 1'b1;
            end else begin
                move_count <= move_count + 1'b1;
            end

            if (iters_count == ITERS_DIV-1) begin
                iters_count <= '0;
                iters_tick  <= 1'b1;
            end else begin
                iters_count <= iters_count + 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin : debounce_all
        logic [7:0] next_up;
        logic [7:0] next_down;
        logic [7:0] next_left;
        logic [7:0] next_right;
        logic [7:0] next_fire;
        logic [7:0] next_restore;
        if (rst) begin
            hist_up      <= 8'd0;
            hist_down    <= 8'd0;
            hist_left    <= 8'd0;
            hist_right   <= 8'd0;
            hist_fire    <= 8'd0;
            hist_restore <= 8'd0;
            pressed      <= 6'd0;
            pressed_d    <= 6'd0;
        end else begin
            pressed_d <= pressed;
            if (sample_tick) begin
                next_up      = {hist_up[6:0],      ~joy_n_ff2[0]};
                next_down    = {hist_down[6:0],    ~joy_n_ff2[1]};
                next_left    = {hist_left[6:0],    ~joy_n_ff2[2]};
                next_right   = {hist_right[6:0],   ~joy_n_ff2[3]};
                next_fire    = {hist_fire[6:0],    ~joy_n_ff2[4]};
                next_restore = {hist_restore[6:0], ~joy_n_ff2[5]};

                hist_up      <= next_up;
                hist_down    <= next_down;
                hist_left    <= next_left;
                hist_right   <= next_right;
                hist_fire    <= next_fire;
                hist_restore <= next_restore;

                if (&next_up)         pressed[0] <= 1'b1;
                else if (~|next_up)   pressed[0] <= 1'b0;
                if (&next_down)       pressed[1] <= 1'b1;
                else if (~|next_down) pressed[1] <= 1'b0;
                if (&next_left)       pressed[2] <= 1'b1;
                else if (~|next_left) pressed[2] <= 1'b0;
                if (&next_right)       pressed[3] <= 1'b1;
                else if (~|next_right) pressed[3] <= 1'b0;
                if (&next_fire)       pressed[4] <= 1'b1;
                else if (~|next_fire) pressed[4] <= 1'b0;
                if (&next_restore)       pressed[5] <= 1'b1;
                else if (~|next_restore) pressed[5] <= 1'b0;
            end
        end
    end

    // UI control logic.
    always_comb begin
        move_up          = up    & ~fire;
        move_down        = down  & ~fire;
        move_left        = left  & ~fire;
        move_right       = right & ~fire;
        zoom_in_pulse    = fire & pressed_pulse[0];
        zoom_out_pulse   = fire & pressed_pulse[1];
        iters_dec_pulse  = fire & left  & iters_tick;
        iters_inc_pulse  = fire & right & iters_tick;
        zoom_reset_pulse = pressed_pulse[5];
    end

endmodule
