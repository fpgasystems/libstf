`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * This module is able to materialize a column based on a random sequences of column identifiers 
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
    parameter NUM_ELEMENTS,
    parameter NUM_BANKS = 16
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in_values, // #(value_t, NUM_ELEMENTS)
    ndata_i.s in_ids,    // #(id_t,    NUM_ELEMENTS)

    ndata_i.m out // #(value_t, NUM_ELEMENTS)
);

`RESET_RESYNC // Reset pipelining

localparam ID_BITS = $bits(id_t);
localparam MAX_IN_TRANSIT = 64;
localparam LOG_NUM_ELEMENTS = $clog2(NUM_ELEMENTS);
localparam LOG_NUM_BANKS = $clog2(NUM_BANKS);
localparam LOG_MAX_IN_TRANSIT = $clog2(MAX_IN_TRANSIT);
localparam SERIAL_WIDTH = LOG_MAX_IN_TRANSIT + LOG_NUM_ELEMENTS;

typedef logic[SERIAL_WIDTH - 1:0]            full_serial_t;
typedef logic[LOG_MAX_IN_TRANSIT - 1:0]      serial_t;
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

ndata_i  #(value_t, NUM_BANKS) values_converted();

ndata_i  #(id_t, NUM_ELEMENTS) creditor_out();
ndata_i  #(id_t, NUM_ELEMENTS) deduplicate_out();
tagged_i #(id_t, SERIAL_WIDTH) decoupler_out[NUM_ELEMENTS]();

data_i #(value_t) value_decoupler_out[NUM_BANKS]();

valid_i #(logic[NUM_ELEMENTS:0]) coupler_mask(); // NUM_ELEMENTS keep bits and 1 last bit
duplicate_i #(NUM_ELEMENTS) deduplicate_mask(); 

tagged_i #(serial_id_t, LOG_NUM_BANKS) pre_cross_in[NUM_ELEMENTS]();
data_i   #(serial_id_t)                pre_cross_out[NUM_BANKS]();

data_i #(full_serial_value_t) bank_out[NUM_BANKS]();

tagged_i #(serial_value_t, LOG_NUM_ELEMENTS) post_cross_in[NUM_BANKS]();
data_i   #(serial_value_t)                   post_cross_out[NUM_ELEMENTS]();

tagged_i #(value_t, LOG_MAX_IN_TRANSIT) reorder_in[NUM_ELEMENTS]();
data_i   #(value_t)                     reorder_out[NUM_ELEMENTS]();

ndata_i  #(value_t, NUM_ELEMENTS)       coupler_out();

// Decouple values
NDataWidthConverter #(
    .data_t(value_t)
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

Creditor #(
    .MAX_IN_TRANSIT(MAX_IN_TRANSIT)
) inst_creditor (
    .clk(clk),
    .rst_n(reset_synced),

    .in(in_ids),
    .out(creditor_out),

    .credit_return(out.valid && out.ready)
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

ReorderDecoupler #(
    .data_t(id_t),
    .NUM_ELEMENTS(NUM_ELEMENTS),
    .SERIAL_WIDTH(SERIAL_WIDTH)
) inst_id_decoupler (
    .clk(clk),
    .rst_n(reset_synced),

    .in(deduplicate_out),
    .out(decoupler_out)
);

for (genvar I = 0; I < NUM_ELEMENTS; I++) begin
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
for (genvar I = 0; I < NUM_BANKS; I++) begin
    DictionaryBank #(
        .value_t(value_t),
        .id_t(bank_id_t)
    ) inst_bank (
        .clk(clk),
        .rst_n(reset_synced),

        .in_value(value_decoupler_out[I]),
        .in_id(pre_cross_out[I]),

        .out(bank_out[I])
    );

    assign bank_out[I].ready = post_cross_in[I].ready;

    assign post_cross_in[I].data.value  = bank_out[I].data.value;
    assign post_cross_in[I].data.serial = bank_out[I].data.serial[LOG_NUM_ELEMENTS+:LOG_MAX_IN_TRANSIT];
    assign post_cross_in[I].tag         = bank_out[I].data.serial[0+:LOG_NUM_ELEMENTS];
    assign post_cross_in[I].keep        = bank_out[I].keep;
    assign post_cross_in[I].last        = bank_out[I].last;
    assign post_cross_in[I].valid       = bank_out[I].valid;
end

// 3. Crossbar after the banks to shuffle the tuples to their original lanes
Crossbar #(
  .data_t(serial_value_t),
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

for (genvar I = 0; I < NUM_ELEMENTS; I++) begin
    assign post_cross_out[I].ready = reorder_in[I].ready;

    assign reorder_in[I].data  = post_cross_out[I].data.value;
    assign reorder_in[I].tag   = post_cross_out[I].data.serial;
    assign reorder_in[I].keep  = post_cross_out[I].keep;
    assign reorder_in[I].last  = post_cross_out[I].last;
    assign reorder_in[I].valid = post_cross_out[I].valid;

    Reorder #(
        .data_t(value_t),
        .DEPTH(MAX_IN_TRANSIT)
    ) inst_reorder (
        .clk(clk),
        .rst_n(reset_synced),

        .in(reorder_in[I]),
        .out(reorder_out[I])
    );
end

Coupler #(
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
