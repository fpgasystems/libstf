`timescale 1ns / 1ps

/**
 * Demultiplexes one input data stream into a set of output data streams based on a select 
 * configuration.
 */
module DataDemultiplexer #(
    parameter NUM_STREAMS
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s select, // #(logic[$clog2(NUM_STREAMS) - 1:0])

    ndata_i.s in,              // #(data_t, NUM_ELEMENTS)
    ndata_i.m out[NUM_STREAMS] // #(data_t, NUM_ELEMENTS)
);

typedef logic[$clog2(NUM_STREAMS) - 1:0] select_t;

// If we don't pull this into an internal register we have to assign valid to ready which is bad
select_t select_reg; 
logic    select_reg_valid;

logic selected_stream_ready;
logic[NUM_STREAMS - 1:0] is_selected, stream_ready;
logic was_last_data_beat;

always_ff @(posedge clk) begin
    if (rst_n == 1'b0) begin
        select_reg_valid <= 1'b0;
    end else begin
        if (select.valid) begin
            if (select.ready) begin
                select_reg       <= select.data;
                select_reg_valid <= 1'b1;
            end
        end else begin
            select_reg <= select_reg;

            if (was_last_data_beat) begin
                select_reg_valid <= '0;
            end else begin
                select_reg_valid <= select_reg_valid;
            end
        end
    end
end

assign selected_stream_ready = select_reg_valid && |(is_selected & stream_ready);
assign was_last_data_beat    = in.valid && in.last && selected_stream_ready;
assign select.ready          = !select_reg_valid || was_last_data_beat;

assign in.ready = selected_stream_ready;

for (genvar I = 0; I < NUM_STREAMS; I++) begin
    assign is_selected[I] = I == select_reg;
    assign stream_ready[I] = out[I].ready;

    assign out[I].data = in.data;
    assign out[I].keep = in.keep;
    assign out[I].last = in.last;
    assign out[I].valid = in.valid && select_reg_valid && is_selected[I];
end

endmodule
