`timescale 1ns / 1ps

import libstf::*;

/**
 * Module for looking ahead
 */
module Lookahead #(
    parameter type data_t,
    parameter int NUM_ELEMENTS,
    parameter int PREVIEW_SIZE = 3
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in,       // #(data_t, NUM_ELEMENTS)
    ndata_i.m out       // #(data_t, 2 * NUM_ELEMENTS)
);

typedef struct packed {
    data_t [NUM_ELEMENTS+PREVIEW_SIZE-1:0] data;
    logic [NUM_ELEMENTS+PREVIEW_SIZE-1:0] keep;
} buffer_t;

typedef enum logic [1:0] {
    ST_WAIT_FIRST,
    ST_GLUE,
    ST_EMIT_LAST
} state_t;
state_t state;

buffer_t preview_buffer;
for (genvar i = 0; i < PREVIEW_SIZE; ++i) begin
    assign preview_buffer.data[NUM_ELEMENTS + i] = in.data[i];
    assign preview_buffer.keep[NUM_ELEMENTS + i] = in.keep[i] && in.valid;
end

logic do_ingest;
assign do_ingest =
    (state == ST_WAIT_FIRST) ||
    (((state == ST_GLUE && in.valid) || state == ST_EMIT_LAST) && out.ready);

task update_preview();
    for ( int i = 0; i < NUM_ELEMENTS; ++i ) begin
        preview_buffer.data[i] <= in.data[i];
        preview_buffer.keep[i] <= in.keep[i];
    end
endtask

always_ff @( posedge clk ) begin : WordGlue_FSM
    if ( !rst_n ) begin
        state <= ST_WAIT_FIRST;
    end else begin
        case ( state )
            ST_WAIT_FIRST: begin
                if ( in.valid ) begin
                    state <= in.last ? ST_EMIT_LAST : ST_GLUE;
                end
            end
            ST_GLUE: begin
                if ( in.valid && out.ready ) begin
                    state <= in.last ? ST_EMIT_LAST : ST_GLUE;
                end
            end
            ST_EMIT_LAST: begin
                if ( out.ready ) begin
                    if ( in.valid && in.last ) begin
                        state <= ST_EMIT_LAST;
                    end else if ( in.valid ) begin
                        state <= ST_GLUE;
                    end else begin
                        state <= ST_WAIT_FIRST;
                    end
                end
            end
        endcase;

        if (do_ingest) begin
            update_preview();
        end
    end
end

assign in.ready = 
    state == ST_WAIT_FIRST || (state == ST_GLUE && out.ready);
assign out.valid = state == ST_EMIT_LAST || (state == ST_GLUE && in.valid);
assign out.data = preview_buffer.data;
assign out.keep = preview_buffer.keep;
assign out.last = state == ST_EMIT_LAST;

endmodule
