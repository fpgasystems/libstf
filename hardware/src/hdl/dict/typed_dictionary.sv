`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * A Dictionary for 32, 64 and 128 bit values. The Dictionary holds 32 bit entries, so a value that
 * takes FACTOR entries is looked up as the entries FACTOR * id to FACTOR * id + FACTOR - 1.
 *
 * Every values stream is followed by one ids stream. The type of the values stream selects the path
 * of the ids and the type of the output.
 */
module TypedDictionary
    import libstf::*;
#(
    parameter type id_t,
    parameter DATABEAT_SIZE,
    localparam type typed_dictionary_data_t = data32_t,
    localparam int TYPED_DICTIONARY_DATA_SIZE = $bits(typed_dictionary_data_t) / 8,
    parameter NUM_ELEMENTS = DATABEAT_SIZE / TYPED_DICTIONARY_DATA_SIZE,
    parameter NUM_BANKS = 16,
    // Number of 32 bit values the dictionary can hold (a 64 bit value takes two entries, a 128 bit value four)
    parameter longint NUM_VALUES = longint'(2) ** $bits(id_t)
) (
    input logic clk,
    input logic rst_n,

    typed_ndata_i.s in_values, // #(DATABEAT_SIZE)
    ndata_i.s in_ids,          // #(id_t, NUM_ELEMENTS)

    typed_ndata_i.m out        // #(DATABEAT_SIZE)
);

`ASSERT_ELAB(DATABEAT_SIZE == NUM_ELEMENTS * TYPED_DICTIONARY_DATA_SIZE)

localparam int NUM_PATHS = 3; // 32, 64 and 128 bit values

typedef logic[$clog2(NUM_PATHS) - 1:0] path_t;

function automatic path_t type_to_path(type_t typ);
    case (GET_TYPE_WIDTH(typ))
        64:      return path_t'(1);
        128:     return path_t'(2);
        default: return path_t'(0);
    endcase
endfunction

// -- Values ---------------------------------------------------------------------------------------
ready_valid_i #(type_t) values_type(clk, rst_n);
ndata_i #(typed_dictionary_data_t, NUM_ELEMENTS) dictionary_in_values(clk, rst_n);

// The type of a values stream is taken with its last beat
assign values_type.data  = in_values.typ;
assign values_type.valid = in_values.valid && in_values.last && dictionary_in_values.ready;

for (genvar I = 0; I < NUM_ELEMENTS; I++) begin
    assign dictionary_in_values.data[I] = in_values.data[I * TYPED_DICTIONARY_DATA_SIZE +: TYPED_DICTIONARY_DATA_SIZE];
    assign dictionary_in_values.keep[I] = &in_values.keep[I * TYPED_DICTIONARY_DATA_SIZE +: TYPED_DICTIONARY_DATA_SIZE];
end
assign dictionary_in_values.last  = in_values.last;
assign dictionary_in_values.valid = in_values.valid && (!in_values.last || values_type.ready);
assign in_values.ready            = dictionary_in_values.ready && (!in_values.last || values_type.ready);

ready_valid_i #(type_t) values_type_buffered(clk, rst_n);
ready_valid_i #(type_t) types[3](clk, rst_n);
SkidBuffer #(type_t) inst_values_type_skid_buffer (.clk(clk), .rst_n(rst_n), .in(values_type), .out(values_type_buffered));
ReadyValidDuplicator #(3) inst_type_duplicator (.clk(clk), .rst_n(rst_n), .in(values_type_buffered), .out(types));

ready_valid_i #(path_t) demux_select(clk, rst_n);
ready_valid_i #(path_t) mux_select(clk, rst_n);

assign demux_select.data  = type_to_path(types[0].data);
assign demux_select.valid = types[0].valid;
assign types[0].ready     = demux_select.ready;

assign mux_select.data  = type_to_path(types[1].data);
assign mux_select.valid = types[1].valid;
assign types[1].ready   = mux_select.ready;

// -- Ids ------------------------------------------------------------------------------------------
ndata_i #(id_t, NUM_ELEMENTS) path_in[NUM_PATHS](clk, rst_n);
ndata_i #(id_t, NUM_ELEMENTS) path_out[NUM_PATHS](clk, rst_n);

DataDemultiplexer #(NUM_PATHS) inst_ids_demux (
    .clk(clk),
    .rst_n(rst_n),

    .select(demux_select),

    .in(in_ids),
    .out(path_in)
);

for (genvar P = 0; P < NUM_PATHS; P++) begin : gen_paths
    localparam int FACTOR = 2 ** P;

    ndata_i #(id_t, NUM_ELEMENTS * FACTOR) expanded(clk, rst_n);
    ndata_i #(id_t, NUM_ELEMENTS * FACTOR) expanded_buffered(clk, rst_n);

    for (genvar I = 0; I < NUM_ELEMENTS; I++) begin
        for (genvar J = 0; J < FACTOR; J++) begin
            assign expanded.data[I * FACTOR + J] = path_in[P].data[I] * FACTOR + J;
            assign expanded.keep[I * FACTOR + J] = path_in[P].keep[I];
        end
    end
    assign expanded.last    = path_in[P].last;
    assign expanded.valid   = path_in[P].valid;
    assign path_in[P].ready = expanded.ready;

    NDataSkidBuffer #(id_t, NUM_ELEMENTS * FACTOR) inst_skid_buffer (.clk(clk), .rst_n(rst_n), .in(expanded), .out(expanded_buffered));
    NDataWidthConverter #(id_t) inst_width_converter (.clk(clk), .rst_n(rst_n), .in(expanded_buffered), .out(path_out[P]));
end

ndata_i #(id_t, NUM_ELEMENTS) entry_ids(clk, rst_n);
ndata_i #(id_t, NUM_ELEMENTS) dictionary_in_ids(clk, rst_n);

DataMultiplexer #(id_t, NUM_ELEMENTS, NUM_PATHS) inst_ids_mux (
    .clk(clk),
    .rst_n(rst_n),

    .select(mux_select),

    .in(path_out),
    .out(entry_ids)
);

NDataSkidBuffer #(id_t, NUM_ELEMENTS) inst_ids_skid_buffer (.clk(clk), .rst_n(rst_n), .in(entry_ids), .out(dictionary_in_ids));

// -- Assertions -----------------------------------------------------------------------------------
`ifndef SYNTHESIS
assert property (@(posedge clk) disable iff (!rst_n) !values_type.valid || GET_TYPE_WIDTH(values_type.data) inside {32, 64, 128})
else $fatal(1, "Module TypedDictionary only supports 32, 64 and 128 bit types, instead got %0d bits", GET_TYPE_WIDTH(values_type.data));
`endif

// -- Dictionary -----------------------------------------------------------------------------------
ndata_i #(typed_dictionary_data_t, NUM_ELEMENTS) dictionary_out(clk, rst_n);

Dictionary #(
    .value_t(typed_dictionary_data_t),
    .id_t(id_t),
    .NUM_ELEMENTS(NUM_ELEMENTS),
    .NUM_BANKS(NUM_BANKS),
    .NUM_VALUES(NUM_VALUES)
) inst_dictionary (
    .clk(clk),
    .rst_n(rst_n),

    .in_values(dictionary_in_values),
    .in_ids(dictionary_in_ids),

    .out(dictionary_out)
);

ndata_i #(data8_t, DATABEAT_SIZE) out_bytes(clk, rst_n);

for (genvar I = 0; I < NUM_ELEMENTS; I++) begin
    assign out_bytes.data[I * TYPED_DICTIONARY_DATA_SIZE +: TYPED_DICTIONARY_DATA_SIZE] = dictionary_out.data[I];
    assign out_bytes.keep[I * TYPED_DICTIONARY_DATA_SIZE +: TYPED_DICTIONARY_DATA_SIZE] = {TYPED_DICTIONARY_DATA_SIZE{dictionary_out.keep[I]}};
end
assign out_bytes.last       = dictionary_out.last;
assign out_bytes.valid      = dictionary_out.valid;
assign dictionary_out.ready = out_bytes.ready;

NDataToTypedNData #(DATABEAT_SIZE) inst_out_type (
    .clk(clk),
    .rst_n(rst_n),

    .in_type(types[2]),
    .in(out_bytes),

    .out(out)
);

endmodule
