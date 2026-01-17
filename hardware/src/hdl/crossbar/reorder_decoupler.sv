`timescale 1ns / 1ps

/**
 * The ReorderDecoupler splits up data beats of an ndata stream into individual data streams per 
 * element and assigns them a serial number in the tag field for later reordering with the Reorder 
 * module.
 */
module ReorderDecoupler #(
    parameter type data_t, 
    parameter NUM_ELEMENTS,
    parameter SERIAL_WIDTH
) (
    input logic clk,
    input logic rst_n,
    
    ndata_i.s  in,               // #(data_t, NUM_ELEMENTS)
    tagged_i.m out[NUM_ELEMENTS] // #(data_t, SERIAL_WIDTH)
);

typedef logic[SERIAL_WIDTH - 1:0] serial_t;

typedef struct packed {
    data_t   data;
    serial_t serial;
} serial_data_t;

ntagged_i #(data_t, SERIAL_WIDTH, NUM_ELEMENTS) enumerator_out();

ndata_i #(serial_data_t, NUM_ELEMENTS) decoupler_in();
data_i  #(serial_data_t)               decoupler_out[NUM_ELEMENTS]();

ReorderEnumerator #(
    .data_t(data_t),
    .NUM_ELEMENTS(NUM_ELEMENTS),
    .SERIAL_WIDTH(SERIAL_WIDTH)
) inst_enumerator (
    .clk(clk),
    .rst_n(rst_n),

    .in(in),
    .out(enumerator_out)
);

for (genvar I = 0; I < NUM_ELEMENTS; I++) begin
    assign decoupler_in.data[I].data   = enumerator_out.data[I];
    assign decoupler_in.data[I].serial = enumerator_out.tag[I];
end

assign decoupler_in.keep    = enumerator_out.keep;
assign decoupler_in.last    = enumerator_out.last;
assign decoupler_in.valid   = enumerator_out.valid;
assign enumerator_out.ready = decoupler_in.ready;

Decoupler #(
    .data_t(serial_data_t),
    .NUM_ELEMENTS(NUM_ELEMENTS)
) inst_decoupler (
    .clk(clk),
    .rst_n(rst_n),

    .in(decoupler_in),
    .out(decoupler_out)
);

for (genvar I = 0; I < NUM_ELEMENTS; I++) begin
    assign out[I].data  = decoupler_out[I].data.data;
    assign out[I].tag   = decoupler_out[I].data.serial;
    assign out[I].keep  = decoupler_out[I].keep;
    assign out[I].last  = decoupler_out[I].last;
    assign out[I].valid = decoupler_out[I].valid;
    assign decoupler_out[I].ready = out[I].ready;
end

endmodule
