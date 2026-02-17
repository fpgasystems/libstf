`timescale 1ns / 1ps

module TypedNDataMultiplexer #(
    parameter DATABEAT_SIZE,
    parameter NUM_STREAMS
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s select, // #(logic[$clog2(NUM_STREAMS) - 1:0])

    typed_ndata_i.s in[NUM_STREAMS], // #(DATABEAT_SIZE)
    typed_ndata_i.m out              // #(DATABEAT_SIZE)
);

typedef data8_t[DATABEAT_SIZE - 1:0] ndata_t;
typedef logic[DATABEAT_SIZE - 1:0]   nkeep_t;

logic[NUM_STREAMS - 1:0] selected;

ndata_t[NUM_STREAMS - 1:0] in_data;
type_t[NUM_STREAMS - 1:0]  in_typ;
nkeep_t[NUM_STREAMS - 1:0] in_keep;
logic[NUM_STREAMS - 1:0]   in_last;
logic[NUM_STREAMS - 1:0]   in_valid;

assign select.ready = out.valid && out.last && out.ready;

for (genvar I = 0; I < NUM_STREAMS; I++) begin
    assign selected[I] = I == select.data;

    assign in[I].ready = select.valid && selected[I] && out.ready;

    assign in_data[I]  = in[I].data;
    assign in_typ[I]   = in[I].typ;
    assign in_keep[I]  = in[I].keep;
    assign in_last[I]  = in[I].last;
    assign in_valid[I] = in[I].valid;
end

always_comb begin
    // We need to provide default values to prevent latch inference
    out.data  = 'x;
    out.typ   = BYTE_T;
    out.keep  = 'x;
    out.last  = 1'bx;
    out.valid = 1'b0;

    if (select.valid) begin
        for (int i = 0; i < NUM_STREAMS; i++) begin
            if (selected[i]) begin
                out.data  = in_data[i];
                out.typ   = in_typ[i];
                out.keep  = in_keep[i];
                out.last  = in_last[i];
                out.valid = in_valid[i];
            end
        end
    end
end

endmodule
