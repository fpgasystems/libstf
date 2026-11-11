`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * This module is able to materialize a column based on a random sequence of column identifiers
 * (e.g., the build-side result of a hash join).
 *
 * It has two phases:
 * 1. The column values are ingested through the in_values interface and stored in an internal BRAM
 *    cache.
 * 2. The column ids are streamed through the in_ids interface and the corresponding values are
 *    returned through the out interface.
 *
 * The module is implemented as NUM_BANKS CachedMaterializerBanks which implement a BRAM cache each
 * and a surrounding crossbar setup which shuffles the column identifiers to their corresponding
 * bank based on the lowest bits and reorders the returned values into the same order.
 */
module Dictionary #(
    parameter type value_t,
    parameter type id_t,
    parameter int NUM_ELEMENTS,
    parameter int NUM_BANKS = 16,
    // Number of values the dictionary can hold, a multiple of NUM_BANKS. Every bank holds
    // NUM_VALUES / NUM_BANKS of them, so a bank depth that fills whole RAM cells does not need the
    // next power of two.
    parameter longint NUM_VALUES = longint'(2) ** $bits(id_t)
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in_values, // #(value_t, NUM_ELEMENTS)
    ndata_i.s in_ids,    // #(id_t,    NUM_ELEMENTS)

    ndata_i.m out // #(value_t, NUM_ELEMENTS)
);

`ASSERT_ELAB(NUM_ELEMENTS == in_ids.NUM_ELEMENTS)

`RESET_RESYNC // Reset pipelining

localparam int ID_BITS = $bits(id_t);
localparam int MAX_IN_TRANSIT = 64;
localparam int LOG_NUM_ELEMENTS = $clog2(NUM_ELEMENTS);
localparam int LOG_NUM_BANKS = $clog2(NUM_BANKS);
localparam int LOG_MAX_IN_TRANSIT = $clog2(MAX_IN_TRANSIT);
localparam int SERIAL_WIDTH = LOG_MAX_IN_TRANSIT + LOG_NUM_ELEMENTS;
localparam int BANK_DEPTH = NUM_VALUES / NUM_BANKS;

`ASSERT_ELAB(NUM_VALUES % NUM_BANKS == 0)
`ASSERT_ELAB(NUM_VALUES <= longint'(2) ** ID_BITS)
`ASSERT_ELAB(NUM_ELEMENTS > 1 && 2 ** $clog2(NUM_ELEMENTS) == NUM_ELEMENTS,
    "NUM_ELEMENTS has to be a power of two > 1")
`ASSERT_ELAB(NUM_BANKS > 1 && 2 ** $clog2(NUM_BANKS) == NUM_BANKS,
    "NUM_BANKS has to be a power of two > 1")
`ASSERT_ELAB(ID_BITS > LOG_NUM_BANKS, "The lowest id bits select the bank")

typedef logic[SERIAL_WIDTH - 1:0]            full_serial_t;
typedef logic[LOG_MAX_IN_TRANSIT - 1:0]      serial_t;
typedef logic[LOG_NUM_BANKS - 1:0]           bank_t;
typedef logic[LOG_NUM_ELEMENTS - 1:0]        lane_t;
typedef logic[ID_BITS - LOG_NUM_BANKS - 1:0] bank_id_t;

typedef struct packed {
    bank_id_t     id;
    full_serial_t serial;
} serial_id_t;

typedef struct packed {
    value_t       value;
    full_serial_t serial;
} full_serial_value_t;

typedef struct packed {
    value_t  value;
    serial_t serial;
} serial_value_t;

ndata_i  #(value_t, NUM_BANKS) values_converted(clk, rst_n);

ndata_i  #(id_t, NUM_ELEMENTS) creditor_out(clk, rst_n);
ndata_i  #(id_t, NUM_ELEMENTS) deduplicate_out(clk, rst_n);
ndata_i  #(id_t, NUM_ELEMENTS) decoupler_in(clk, rst_n);
tagged_i #(id_t, full_serial_t) decoupler_out[NUM_ELEMENTS](clk, rst_n);

data_i #(value_t) value_decoupler_out[NUM_BANKS](clk, rst_n);

valid_i #(logic[NUM_ELEMENTS:0]) coupler_mask(clk, rst_n); // NUM_ELEMENTS keep bits and 1 last bit
duplicate_i #(NUM_ELEMENTS) deduplicate_mask();

tagged_i #(serial_id_t, bank_t) pre_cross_in[NUM_ELEMENTS](clk, rst_n);
data_i   #(serial_id_t)                pre_cross_out[NUM_BANKS](clk, rst_n);

data_i #(full_serial_value_t) bank_out[NUM_BANKS](clk, rst_n);

tagged_i #(serial_value_t, lane_t) post_cross_in[NUM_BANKS](clk, rst_n);
data_i   #(serial_value_t)                   post_cross_out[NUM_ELEMENTS](clk, rst_n);

tagged_i #(value_t, serial_t) reorder_in[NUM_ELEMENTS](clk, rst_n);
data_i   #(value_t)                     reorder_out[NUM_ELEMENTS](clk, rst_n);

ndata_i  #(value_t, NUM_ELEMENTS)       coupler_out(clk, rst_n);

// Decouple values
NDataWidthConverter #(
    .data_t(value_t),
    .IN_WIDTH(NUM_ELEMENTS),
    .OUT_WIDTH(NUM_BANKS)
) inst_width_converter (
    .clk(clk),
    .rst_n(reset_synced),

    .in(in_values),
    .out(values_converted)
);

Decoupler #(
    .data_t(value_t),
    .NUM_ELEMENTS(NUM_BANKS)
) inst_value_decoupler (
    .clk(clk),
    .rst_n(reset_synced),

    .in(values_converted),
    .out(value_decoupler_out)
);

// 1. Distribution of tuples to the respective bank that stores the value to materialize
assign coupler_mask.data  = {deduplicate_out.keep, deduplicate_out.last};
assign coupler_mask.valid = deduplicate_out.valid && deduplicate_out.ready;

logic credit_return;
ShiftRegister #(.WIDTH(1), .LEVELS(1)) inst_credit_return_sr (
    .clk(clk),
    .rst_n(reset_synced),

    .in_data(out.valid && out.ready),
    .out_data(credit_return)
);

Creditor #(
    .MAX_IN_TRANSIT(MAX_IN_TRANSIT)
) inst_creditor (
    .clk(clk),
    .rst_n(reset_synced),

    .in(in_ids),
    .out(creditor_out),

    .credit_return(credit_return)
);

Deduplicate #(
    .data_t(id_t),
    .NUM_ELEMENTS(NUM_ELEMENTS)
) inst_deduplicate (
    .clk(clk),
    .rst_n(reset_synced),

    .in(creditor_out),
    .mask(deduplicate_mask),
    .out(deduplicate_out)
);

NDataSkidBuffer #(id_t, NUM_ELEMENTS) inst_decoupler_skid_buffer (
    .clk(clk),
    .rst_n(reset_synced),

    .in(deduplicate_out),
    .out(decoupler_in)
);

ReorderDecoupler #(
    .data_t(id_t),
    .serial_t(full_serial_t),
    .NUM_ELEMENTS(NUM_ELEMENTS)
) inst_id_decoupler (
    .clk(clk),
    .rst_n(reset_synced),

    .in(decoupler_in),
    .out(decoupler_out)
);

for (genvar I = 0; I < NUM_ELEMENTS; I++) begin : gen_pre_crossbar_lanes
    assign decoupler_out[I].ready = pre_cross_in[I].ready;

    assign pre_cross_in[I].data.id     = decoupler_out[I].data[ID_BITS - 1:LOG_NUM_BANKS];
    assign pre_cross_in[I].data.serial = decoupler_out[I].tag;
    assign pre_cross_in[I].tag         = decoupler_out[I].data[LOG_NUM_BANKS - 1:0];
    assign pre_cross_in[I].keep        = decoupler_out[I].keep;
    assign pre_cross_in[I].last        = decoupler_out[I].last;
    assign pre_cross_in[I].valid       = decoupler_out[I].valid;
end

Crossbar #(
    .data_t(serial_id_t),
    .tag_t(bank_t),
    .NUM_INPUTS(NUM_ELEMENTS),
    .NUM_OUTPUTS(NUM_BANKS),
    .LAST_HANDLING(0) // WAIT_ALL
) inst_pre_crossbar (
    .clk(clk),
    .rst_n(reset_synced),

    .in(pre_cross_in),
    .out(pre_cross_out)
);

// 2. Banks to materialize the values
for (genvar I = 0; I < NUM_BANKS; I++) begin : gen_banks
    DictionaryBank #(
        .value_t(value_t),
        .id_t(bank_id_t),
        .DEPTH(BANK_DEPTH)
    ) inst_bank (
        .clk(clk),
        .rst_n(reset_synced),

        .in_value(value_decoupler_out[I]),
        .in_id(pre_cross_out[I]),

        .out(bank_out[I])
    );

    assign bank_out[I].ready = post_cross_in[I].ready;

    assign post_cross_in[I].data.value  = bank_out[I].data.value;
    assign post_cross_in[I].data.serial =
        bank_out[I].data.serial[LOG_NUM_ELEMENTS+:LOG_MAX_IN_TRANSIT];
    assign post_cross_in[I].tag         = bank_out[I].data.serial[0+:LOG_NUM_ELEMENTS];
    assign post_cross_in[I].keep        = bank_out[I].keep;
    assign post_cross_in[I].last        = bank_out[I].last;
    assign post_cross_in[I].valid       = bank_out[I].valid;
end

// 3. Crossbar after the banks to shuffle the tuples to their original lanes
Crossbar #(
  .data_t(serial_value_t),
  .tag_t(lane_t),
  .NUM_INPUTS(NUM_BANKS),
  .NUM_OUTPUTS(NUM_ELEMENTS),
  .LAST_HANDLING(1), // FORWARD
  .FILTER_KEEP(0)
) inst_post_crossbar (
  .clk(clk),
  .rst_n(reset_synced),

  .in(post_cross_in),
  .out(post_cross_out)
);

for (genvar I = 0; I < NUM_ELEMENTS; I++) begin : gen_post_crossbar_lanes
    assign post_cross_out[I].ready = reorder_in[I].ready;

    assign reorder_in[I].data  = post_cross_out[I].data.value;
    assign reorder_in[I].tag   = post_cross_out[I].data.serial;
    assign reorder_in[I].keep  = post_cross_out[I].keep;
    assign reorder_in[I].last  = post_cross_out[I].last;
    assign reorder_in[I].valid = post_cross_out[I].valid;

    Reorder #(
        .data_t(value_t),
        .serial_t(serial_t),
        .DEPTH(MAX_IN_TRANSIT)
    ) inst_reorder (
        .clk(clk),
        .rst_n(reset_synced),

        .in(reorder_in[I]),
        .out(reorder_out[I])
    );
end

Coupler #(
    .data_t(value_t),
    .NUM_ELEMENTS(NUM_ELEMENTS),
    .MAX_IN_TRANSIT(MAX_IN_TRANSIT)
) inst_coupler (
    .clk(clk),
    .rst_n(reset_synced),

    .mask(coupler_mask),

    .in(reorder_out),
    .out(coupler_out)
);

Duplicate #(
    .data_t(value_t),
    .NUM_ELEMENTS(NUM_ELEMENTS),
    .MAX_IN_TRANSIT(MAX_IN_TRANSIT+64)
) inst_duplicate (
    .clk(clk),
    .rst_n(reset_synced),

    .mask(deduplicate_mask),

    .in(coupler_out),
    .out(out)
);

endmodule
