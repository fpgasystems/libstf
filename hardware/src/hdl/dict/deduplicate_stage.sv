`timescale 1ns / 1ps

module DeduplicateStage  #(
    parameter int unsigned ID,
    parameter type data_t, 
    parameter NUM_ELEMENTS,
    parameter int unsigned START_IDX_INCL,
    parameter int unsigned END_IDX_EXCL
) (
    input logic clk,
    input logic rst_n,

    duplicate_i.s in_mask,   // #(NUM_ELEMENTS)
    ndata_i.s in,              // #(data_t, NUM_ELEMENTS)
    duplicate_i.m out_mask,  // #(NUM_ELEMENTS)
    ndata_i.m out            // #(data_t, NUM_ELEMENTS)
);

typedef struct packed {
    logic duplicate;
    logic [$clog2(NUM_ELEMENTS)-1:0] origin;
} duplicate_t;

`ASSERT_ELAB(START_IDX_INCL < END_IDX_EXCL)

assign in.ready = out.ready;

ndata_i #(data_t, NUM_ELEMENTS) d (), q ();
duplicate_i #(NUM_ELEMENTS) d_mask (), q_mask ();

assign out.data = q.data;
assign out.keep = q.keep;
assign out.valid = q.valid;
assign out.last = q.last;

assign out_mask.duplicates = q_mask.duplicates;
assign out_mask.origins = q_mask.origins;

always_comb begin
    d.data = q.data;
    d.keep = q.keep;
    d.last = q.last;
    d.valid = q.valid;

    d_mask.duplicates = q_mask.duplicates;
    d_mask.origins = q_mask.origins;

    if (in.valid && out.ready) begin
        d.valid = 1;
        d.keep = in.keep;
        d.last = in.last;
        d.data = in.data;

        d_mask.duplicates = in_mask.duplicates;
        d_mask.origins = in_mask.origins;

        for (int unsigned i = START_IDX_INCL; i < END_IDX_EXCL; i++) begin
            for (int unsigned j = 0; j < i; j++) begin
                // j is always less than i
                if (d.data[i] == d.data[j]) begin
                    d_mask.duplicates[i] = d.keep[i];
                    d_mask.origins[i] = j;
                    d.keep[i] = 0;

                    // Break inner loop, otherwise d_mask[i].origin might point to a
                    // location which is itself a duplicate
                    break;
                end
            end
        end
    end else if (out.ready) begin
        //Drain registers
        d.data = 'x;
        d.keep = 'x;
        d.valid = 0;
        d.last = 0;

        d_mask.duplicates = '{NUM_ELEMENTS{0}};
        d_mask.origins = '{default: 'x};
    end
end

always_ff @(posedge clk) begin
    if (~rst_n) begin
        q.data <= 'x;
        q.keep <= 'x;
        q.valid <= 0;
        q.last <= 0;

        q_mask.duplicates <= '{NUM_ELEMENTS{0}};
        q_mask.origins <= '{default: 'x};
    end else begin
        q.data <= d.data;
        q.keep <= d.keep;
        q.valid <= d.valid;
        q.last <= d.last;

        q_mask.duplicates <= d_mask.duplicates;
        q_mask.origins <= d_mask.origins;
    end
end

endmodule
