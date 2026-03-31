/**
 * This module gets rid of data beats with keep == '0.
 */
module NullBeatSuppressor #(
    parameter type data_t,
    parameter NUM_ELEMENTS
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in,  // #(data_t, NUM_ELEMENTS)
    ndata_i.m out  // #(data_t, NUM_ELEMENTS)
);

data_t[NUM_ELEMENTS - 1:0] hold_data,  n_hold_data;
logic[NUM_ELEMENTS - 1:0]  hold_keep,  n_hold_keep;
logic                      hold_last,  n_hold_last;
logic                      hold_valid, n_hold_valid;

logic is_null_last, is_last_or_not_null;

assign is_null_last        = in.keep == '0 && in.last;
assign is_last_or_not_null = in.keep != '0 || in.last;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        hold_valid <= 1'b0;
    end else begin
        hold_data  <= n_hold_data;
        hold_keep  <= n_hold_keep;
        hold_last  <= n_hold_last;
        hold_valid <= n_hold_valid;
    end
end

always_comb begin
    in.ready = 1'b0;

    n_hold_data  = hold_data;
    n_hold_keep  = hold_keep;
    n_hold_last  = hold_last;
    n_hold_valid = hold_valid;

    if (!hold_valid) begin
        n_hold_data  = in.data;
        n_hold_keep  = in.keep;
        n_hold_last  = in.last;
        n_hold_valid = in.valid && is_last_or_not_null;

        in.ready = 1'b1;
    end else begin
        if (out.ready) begin
            if (hold_last || (in.valid && is_last_or_not_null)) begin
                n_hold_data  = in.data;
                n_hold_keep  = in.keep;
                n_hold_last  = in.last;
                n_hold_valid = in.valid && (in.keep != '0 || (hold_last && in.last));

                in.ready = 1'b1;
            end
        end else begin
            if (in.valid && is_null_last) begin
                n_hold_last = 1'b1;
            end
        end
    end
end

assign out.data  = hold_data;
assign out.keep  = hold_keep;
assign out.last  = hold_last || (in.valid && is_null_last); 
assign out.valid = hold_valid && (hold_last || (in.valid && is_last_or_not_null));

endmodule

module AXINullBeatSuppressor #(
    parameter AXI4S_DATA_BITS = AXI_DATA_BITS
) (
    input logic clk,
    input logic rst_n,

    AXI4S.s in, // #(AXI4S_DATA_BITS) 
    AXI4S.m out // #(AXI4S_DATA_BITS) 
);

localparam NUM_ELEMENTS = AXI4S_DATA_BITS / 8;

ndata_i #(data8_t, NUM_ELEMENTS) ndata_in(), ndata_out();

assign ndata_in.data  = in.tdata;
assign ndata_in.keep  = in.tkeep;
assign ndata_in.last  = in.tlast;
assign ndata_in.valid = in.tvalid;
assign in.tready      = ndata_in.ready;

NullBeatSuppressor #(
    .data_t(data8_t),
    .NUM_ELEMENTS(NUM_ELEMENTS)
) inst_null_beat_suppressor (
    .clk(clk),
    .rst_n(rst_n),
    
    .in(ndata_in),
    .out(ndata_out)
);

assign out.tdata       = ndata_out.data;
assign out.tkeep       = ndata_out.keep;
assign out.tlast       = ndata_out.last;
assign out.tvalid      = ndata_out.valid;
assign ndata_out.ready = out.tready;

endmodule
