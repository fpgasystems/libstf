`timescale 1ns / 1ps

import libstf::*;

parameter type typed_dictionary_data_t = data32_t;
parameter int TYPED_DICTIONARY_DATA_SIZE = $bits(typed_dictionary_data_t) / 8;

module TypedDictionary #(
    parameter type id_t,
    parameter DATABEAT_SIZE,
    parameter NUM_ELEMENTS = DATABEAT_SIZE / TYPED_DICTIONARY_DATA_SIZE,
    parameter NUM_BANKS = 16
) (
    input logic clk,
    input logic rst_n,

    typed_ndata_i.s in_values, // #(DATABEAT_SIZE)
    ndata_i.s in_ids,          // #(id_t, NUM_ELEMENTS)

    typed_ndata_i.m out        // #(DATABEAT_SIZE)
);

`ASSERT_ELAB(DATABEAT_SIZE == NUM_ELEMENTS * TYPED_DICTIONARY_DATA_SIZE)

valid_i #(type_t) typ ();
always_ff @(posedge clk) begin
    if (rst_n == 1'b0) begin
        typ.valid <= 0;
    end else if (in_values.ready && in_values.valid) begin
        typ.data <= in_values.typ;
        typ.valid <= 1;
    end
end

ndata_i #(typed_dictionary_data_t, NUM_ELEMENTS) dictionary_in_values ();
ndata_i #(id_t, NUM_ELEMENTS) dictionary_in_ids ();
ndata_i #(typed_dictionary_data_t, NUM_ELEMENTS) dictionary_out ();

assign in_values.ready = dictionary_in_values.ready;
generate
for (genvar i = 0; i < NUM_ELEMENTS; i++) begin
    assign dictionary_in_values.data[i] = in_values.data[(i+1) * TYPED_DICTIONARY_DATA_SIZE - 1:i * TYPED_DICTIONARY_DATA_SIZE];
    assign dictionary_in_values.keep[i] = &in_values.keep[(i+1) * TYPED_DICTIONARY_DATA_SIZE - 1:i * TYPED_DICTIONARY_DATA_SIZE];
end
endgenerate
assign dictionary_in_values.last = in_values.last;
assign dictionary_in_values.valid = in_values.valid;

typedef struct packed {
    // Whether we're buffering some half-input. This is only used if
    // type width is 64 bits, for each second half of the in_ids
    // databeats.
    logic                     valid;

    id_t[NUM_ELEMENTS - 1:0]  data;
    logic[NUM_ELEMENTS - 1:0] keep;
    logic                     last;
} state_t;
state_t state;

// Combinatorial values needed to drive the state machine for in_ids
logic keep_second_half;
always_comb begin
    keep_second_half = 1'b0;
    for (int i = NUM_ELEMENTS/2; i < NUM_ELEMENTS; i++) begin
        keep_second_half |= in_ids.keep[i];
    end
end

id_t[NUM_ELEMENTS * 2 - 1:0] double_ids_data;
logic[NUM_ELEMENTS * 2 - 1:0] double_ids_keep;
generate
for (genvar i = 0; i < NUM_ELEMENTS; i++) begin
    assign double_ids_data[(i+1) * 2 - 1:i * 2] = '{in_ids.data[i] * 2 + 1, in_ids.data[i] * 2};
    assign double_ids_keep[(i+1) * 2 - 1:i * 2] = '{in_ids.keep[i], in_ids.keep[i]};
end
endgenerate

// -- State ----------------------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (rst_n == 1'b0) begin
        state <= '{valid: 0, data: '0, keep: '0, last: 0};
    end else begin
        // If the in/out type is 64 bits wide, we can produce two output
        // databeats for each in_values databeat (if we have NUM_ELEMENTS
        // ids). As such, we must buffer the second half of the databeat
        // and provide it as input to the dictionary decoder in the next batch.
        // This will be done by the the combinatorial logic.
        if (typ.valid && GET_TYPE_WIDTH(typ.data) == 64 && dictionary_in_ids.ready && dictionary_in_ids.valid) begin
            if (state.valid) begin
                // The buffered in_values data has been consumed (since we
                // handshaked on dictionary_in_ids in this cycle), so mark it
                // as invalid.
                state.valid <= 0;
            end else begin
                // If we're consuming a in_ids databeat, we must buffer the
                // second half of it (assuming there are any values to keep in it).
                state <= '{
                  valid: keep_second_half,
                  data: double_ids_data[NUM_ELEMENTS * 2 - 1:NUM_ELEMENTS],
                  keep: double_ids_keep[NUM_ELEMENTS * 2 - 1:NUM_ELEMENTS],
                  last: in_ids.last
                };
            end
        end
    end
end

// -- Assertions -----------------------------------------------------------------------------------
assert property (@(posedge clk) disable iff (!rst_n) !typ.valid || GET_TYPE_WIDTH(typ.data) == 32 || GET_TYPE_WIDTH(typ.data) == 64)
else $fatal(1, "Module TypedDictionary only supports types that are either 32 or 64 bits, instead got %d bits", GET_TYPE_WIDTH(typ.data));

// -- Logic ----------------------------------------------------------------------------------------
always_comb begin
    // We need to provide default values to prevent latch inference
    dictionary_in_ids.data  = 'x;
    dictionary_in_ids.keep  = 'x;
    dictionary_in_ids.last  = 'x;
    dictionary_in_ids.valid = 0;
    in_ids.ready            = 0;

    case (GET_TYPE_WIDTH(typ.data))
        32: begin
            dictionary_in_ids.data   = in_ids.data;
            dictionary_in_ids.keep   = in_ids.keep;
            dictionary_in_ids.last   = in_ids.last;
            dictionary_in_ids.valid  = in_ids.valid;
            in_ids.ready             = dictionary_in_ids.ready;
        end

        64: begin
            if (state.valid) begin
                dictionary_in_ids.data  = state.data;
                dictionary_in_ids.keep  = state.keep;
                dictionary_in_ids.last  = state.last;
                dictionary_in_ids.valid = 1;
                in_ids.ready            = 0;
            end else begin
                dictionary_in_ids.data  = double_ids_data[NUM_ELEMENTS - 1:0];
                dictionary_in_ids.keep  = double_ids_keep[NUM_ELEMENTS - 1:0];
                // We're submitting the first half of the *last* IDs to read,
                // but possibly we have more IDs to read in the second half,
                // and thus we shall send the last signal then (in the next
                // databeat).
                // If, we don't have a second half worth of data to send, then
                // we shall set last to high here.
                dictionary_in_ids.last  = in_ids.last && ~keep_second_half;
                dictionary_in_ids.valid = in_ids.valid;
                in_ids.ready            = dictionary_in_ids.ready;
            end
        end
    endcase
end

Dictionary #(
    .value_t(data32_t),
    .id_t(id_t),
    .NUM_ELEMENTS(NUM_ELEMENTS),
    .NUM_BANKS(NUM_BANKS)
) inst_dictionary (
    .clk(clk),
    .rst_n(rst_n),

    .in_values(dictionary_in_values),
    .in_ids(dictionary_in_ids),

    .out(dictionary_out)
);

assign dictionary_out.ready = typ.valid && out.ready;

generate
for (genvar i = 0; i < NUM_ELEMENTS; i++) begin
    assign out.data[(i+1) * TYPED_DICTIONARY_DATA_SIZE - 1:i * TYPED_DICTIONARY_DATA_SIZE] = dictionary_out.data[i];
    assign out.keep[(i+1) * TYPED_DICTIONARY_DATA_SIZE - 1:i * TYPED_DICTIONARY_DATA_SIZE] = {TYPED_DICTIONARY_DATA_SIZE{dictionary_out.keep[i]}};
end
endgenerate

assign out.typ = typ.data;
assign out.last = dictionary_out.last;
assign out.valid = typ.valid && dictionary_out.valid;

endmodule
