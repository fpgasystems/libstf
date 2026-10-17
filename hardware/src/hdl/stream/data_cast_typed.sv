`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * Casts the elements of a typed ndata stream to the type configured per transfer via `out_type`.
 *
 * Supported casts (all others are rejected by a simulation assertion):
 *   - Same width as in.typ (e.g. INT32_T -> INT32_T): pass-through with one register stage.
 *   - 32 bit -> INT16_T: 2 input beats are packed into 1 output beat.
 *   - 32 bit -> BYTE_T:  4 input beats are packed into 1 output beat.
 *
 * Narrowing keeps the low bytes of every element (truncation), which is correct for signed and
 * unsigned values as long as they fit the narrower type.
 */
module TypedNDataCast
    import libstf::*;
#(
    parameter DATABEAT_SIZE
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s out_type, // #(type_t)

    typed_ndata_i.s in,       // #(DATABEAT_SIZE)
    typed_ndata_i.m out       // #(DATABEAT_SIZE)
);

// The output beat is filled in quarters: one 32 bit -> 8 bit input beat fills one quarter, one
// 32 bit -> 16 bit input beat two quarters, and a pass-through beat all four.
localparam NUM_QUARTERS  = 4;
localparam QUARTER_SIZE  = DATABEAT_SIZE / NUM_QUARTERS; // Bytes per quarter
localparam NUM_32B_LANES = DATABEAT_SIZE / 4;            // 32 bit elements per input beat

`ASSERT_ELAB(DATABEAT_SIZE % 16 == 0)

typedef data8_t[QUARTER_SIZE - 1:0] quarter_t;
typedef logic  [QUARTER_SIZE - 1:0] quarter_keep_t;

// -- Output type ----------------------------------------------------------------------------------
// The output type is held until the last input beat of the transfer is consumed and bypassed in the
// cycle it is accepted.
valid_i #(type_t) keep_type(clk, rst_n);
valid_i #(type_t) typ(clk, rst_n);

logic in_fire;
assign in_fire = in.valid && in.ready;

always_ff @(posedge clk) begin
    if (rst_n == 1'b0) begin
        keep_type.data  <= 'X;
        keep_type.valid <= 1'b0;
    end else begin
        if (out_type.valid && out_type.ready) begin
            keep_type.data  <= out_type.data;
            keep_type.valid <= 1'b1;
        end

        if (in_fire && in.last) begin
            keep_type.valid <= 1'b0;
        end
    end
end

always_comb begin
    typ.data  = keep_type.data;
    typ.valid = 1'b0;

    if (keep_type.valid) begin
        typ.data  = keep_type.data;
        typ.valid = 1'b1;
    end else if (out_type.valid) begin
        typ.data  = out_type.data;
        typ.valid = 1'b1;
    end
end

assign out_type.ready = !keep_type.valid;

// -- Mode -----------------------------------------------------------------------------------------
logic narrow_16, narrow_8;
assign narrow_16 = typ.data == INT16_T && GET_TYPE_WIDTH(in.typ) == 32;
assign narrow_8  = typ.data == BYTE_T  && GET_TYPE_WIDTH(in.typ) == 32;

`ifndef SYNTHESIS
assert property (@(posedge clk) disable iff (!rst_n)
    !(in.valid && typ.valid) || narrow_16 || narrow_8 || GET_TYPE_WIDTH(typ.data) == GET_TYPE_WIDTH(in.typ))
else $fatal(1, "TypedNDataCast does not support casting type %0d to type %0d", in.typ, typ.data);

assert property (@(posedge clk) disable iff (!rst_n)
    !(in.valid && typ.valid && (narrow_16 || narrow_8) && !in.last) || &in.keep)
else $fatal(1, "TypedNDataCast requires a dense input when narrowing");
`endif

// -- Narrowed input -------------------------------------------------------------------------------
// The 16 bit values of one input beat span two quarters, the 8 bit values one quarter.
data8_t[2 * QUARTER_SIZE - 1:0] data_16_bytes;
logic  [2 * QUARTER_SIZE - 1:0] keep_16_bytes;

quarter_t     [1:0] data_16;
quarter_keep_t[1:0] keep_16;
quarter_t           data_8;
quarter_keep_t      keep_8;

for (genvar I = 0; I < NUM_32B_LANES; I++) begin
    assign data_16_bytes[2 * I]     = in.data[4 * I];
    assign data_16_bytes[2 * I + 1] = in.data[4 * I + 1];
    assign keep_16_bytes[2 * I]     = in.keep[4 * I];
    assign keep_16_bytes[2 * I + 1] = in.keep[4 * I];

    assign data_8[I] = in.data[4 * I];
    assign keep_8[I] = in.keep[4 * I];
end

assign data_16 = data_16_bytes;
assign keep_16 = keep_16_bytes;

// -- Gearbox --------------------------------------------------------------------------------------
logic[1:0] pos, n_pos; // Next quarter to fill
logic[2:0] step;       // Quarters filled per input beat
logic      beat_full;

quarter_t     [NUM_QUARTERS - 1:0] in_quarters;
quarter_keep_t[NUM_QUARTERS - 1:0] in_quarters_keep;

quarter_t     [NUM_QUARTERS - 1:0] data,  n_data;
quarter_keep_t[NUM_QUARTERS - 1:0] keep,  n_keep;
type_t                             typ_q, n_typ_q;
logic                              last,  n_last;
logic                              valid, n_valid;

assign in_quarters      = in.data;
assign in_quarters_keep = in.keep;

assign step      = narrow_8 ? 3'd1 : narrow_16 ? 3'd2 : 3'd4;
assign beat_full = 3'(pos) + step == 3'(NUM_QUARTERS);

assign in.ready = typ.valid && (!valid || out.ready);

always_ff @(posedge clk) begin
    if (rst_n == 1'b0) begin
        pos   <= '0;
        data  <= 'X;
        keep  <= 'X;
        typ_q <= type_t'('X);
        last  <= 'X;
        valid <= 1'b0;
    end else begin
        pos   <= n_pos;
        data  <= n_data;
        keep  <= n_keep;
        typ_q <= n_typ_q;
        last  <= n_last;
        valid <= n_valid;
    end
end

always_comb begin
    n_pos   = pos;
    n_data  = data;
    n_keep  = keep;
    n_typ_q = typ_q;
    n_last  = last;
    n_valid = valid && !out.ready;

    if (in_fire) begin
        if (pos == '0) begin
            n_keep = '0;
        end

        for (int q = 0; q < NUM_QUARTERS; q++) begin
            if (narrow_8) begin
                if (pos == 2'(q)) begin
                    n_data[q] = data_8;
                    n_keep[q] = keep_8;
                end
            end else if (narrow_16) begin
                if (pos[1] == 1'(q / 2)) begin
                    n_data[q] = data_16[q % 2];
                    n_keep[q] = keep_16[q % 2];
                end
            end else begin
                n_data[q] = in_quarters[q];
                n_keep[q] = in_quarters_keep[q];
            end
        end

        n_typ_q = typ.data;
        n_last  = in.last;

        if (in.last || beat_full) begin
            n_pos   = '0;
            n_valid = 1'b1;
        end else begin
            n_pos = pos + 2'(step);
        end
    end
end

assign out.data  = data;
assign out.keep  = keep;
assign out.typ   = typ_q;
assign out.last  = last;
assign out.valid = valid;

endmodule
