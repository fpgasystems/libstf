`timescale 1ns / 1ps

// FIFO that reduces an input to smaller chunks as output
module MultiInsertFIFO #(
    parameter int DEPTH, //a power of two except 1
    parameter int WIDTH,
    parameter int FACTOR
) (
    input logic i_clk,
    input logic i_rst_n,

    input  logic[FACTOR * WIDTH - 1:0] i_data,
    input  logic                       i_valid,
    output logic                       o_ready,

    output logic[WIDTH - 1:0] o_data,
    output logic              o_valid,
    input  logic              i_ready,

    output logic[$clog2(DEPTH):0] o_filling_level
);

localparam int SWITCH_WIDTH = $clog2(FACTOR);

logic[SWITCH_WIDTH - 1:0] s_switch, s_next_switch;

logic[FACTOR * WIDTH - 1:0] s_data;
logic s_valid, s_ready;

MehdiFIFO #(
    .DEPTH(DEPTH),
    .WIDTH(FACTOR * WIDTH)
) inst_fifo (
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),

    .i_data(i_data),
    .i_valid(i_valid),
    .i_ready(o_ready),

    .o_data(s_data),
    .o_valid(s_valid),
    .o_ready(s_ready),

    .o_filling_level(o_filling_level)
);

always_ff @(posedge i_clk) begin
    if (i_rst_n == 1'b0) begin
        s_switch <= '0;
    end else begin
        s_switch <= s_next_switch;
    end
end

always_comb begin
    s_next_switch = s_switch;

    if (i_ready == 1'b1 && s_valid == 1'b1) begin
        s_next_switch = s_switch + 1'b1;
    end
end

always_comb begin
    if (i_ready == 1'b1 && s_switch == '1) begin
        s_ready = 1'b1;
    end else begin
        s_ready = 1'b0;
    end
end

assign o_data  = s_data[s_switch * WIDTH +: WIDTH];
assign o_valid = s_valid;

endmodule
