import lynxTypes::*;

`include "axi_macros.svh"

localparam int FIFO_WIDTH  = AXI_DATA_BITS + AXI_DATA_BITS / 8 + 1;
localparam int SMALL_DEPTH = 2;
localparam int LARGE_DEPTH = 16;

typedef logic[FIFO_WIDTH - 1:0] fifo_data_t;

// -- Tie-off unused interfaces and signals --------------------------------------------------------
always_comb axi_ctrl.tie_off_s();
always_comb notify.tie_off_m();
always_comb sq_rd.tie_off_m();
always_comb sq_wr.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb cq_wr.tie_off_s();

for (genvar I = 1; I < N_STRM_AXI; I++) begin : gen_tie_off_host
    always_comb axis_host_recv[I].tie_off_s();
    always_comb axis_host_send[I].tie_off_m();
end
for (genvar I = 0; I < N_CARD_AXI; I++) begin : gen_tie_off_card
    always_comb axis_card_send[I].tie_off_m();
    always_comb axis_card_recv[I].tie_off_s();
end

// -- Fix clock and reset names --------------------------------------------------------------------
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

// -- Signals --------------------------------------------------------------------------------------
fifo_data_t small_out_data, large_out_data;
logic       small_in_ready, small_out_valid, small_out_ready;
logic       large_in_valid, large_in_ready, large_out_valid, large_out_ready;

logic[$clog2(SMALL_DEPTH):0] small_filling_level;
logic[$clog2(LARGE_DEPTH):0] large_filling_level;

logic[15:0] lfsr;
logic[7:0]  cycle;
logic       middle_open, out_open;

// -- Throttling -----------------------------------------------------------------------------------
// The handshake between the FIFOs opens randomly in half of the cycles. The output alternates
// between 64 cycles in which it rarely opens, so the FIFOs fill up, and 64 cycles in which it
// opens most of the time, so the FIFOs run empty.
always_ff @(posedge clk) begin
    if (!rst_n) begin
        lfsr  <= 16'h1;
        cycle <= '0;
    end else begin
        lfsr  <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        cycle <= cycle + 1'b1;
    end
end

assign middle_open = lfsr[0];
assign out_open    = cycle[6] ? lfsr[3:1] != '0 : lfsr[5:1] == '0;

// -- FIFOs ----------------------------------------------------------------------------------------
MehdiFIFO #(
    .DEPTH(SMALL_DEPTH),
    .WIDTH(FIFO_WIDTH),
    .STYLE("distributed")
) inst_small_fifo (
    .clk(clk),
    .rst_n(rst_n),

    .in_data({axis_host_recv[0].tdata, axis_host_recv[0].tkeep, axis_host_recv[0].tlast}),
    .in_valid(axis_host_recv[0].tvalid),
    .in_ready(small_in_ready),

    .out_data(small_out_data),
    .out_valid(small_out_valid),
    .out_ready(small_out_ready),

    .filling_level(small_filling_level)
);

assign axis_host_recv[0].tready = small_in_ready;

assign large_in_valid  = small_out_valid && middle_open;
assign small_out_ready = large_in_ready && middle_open;

MehdiFIFO #(
    .DEPTH(LARGE_DEPTH),
    .WIDTH(FIFO_WIDTH),
    .STYLE("block")
) inst_large_fifo (
    .clk(clk),
    .rst_n(rst_n),

    .in_data(small_out_data),
    .in_valid(large_in_valid),
    .in_ready(large_in_ready),

    .out_data(large_out_data),
    .out_valid(large_out_valid),
    .out_ready(large_out_ready),

    .filling_level(large_filling_level)
);

assign {axis_host_send[0].tdata, axis_host_send[0].tkeep, axis_host_send[0].tlast} = large_out_data;
assign axis_host_send[0].tvalid = large_out_valid && out_open;
assign large_out_ready          = axis_host_send[0].tready && out_open;

// -- Assertions -----------------------------------------------------------------------------------
`ifndef SYNTHESIS
// The in_ready of the FIFOs includes rst_n, so we check the sampled reset instead of disable iff
assert property (@(posedge clk) rst_n |->
    small_filling_level <= SMALL_DEPTH && small_in_ready == (small_filling_level != SMALL_DEPTH))
else $fatal(1, "Small FIFO has filling level %0d but in_ready %0d!",
    small_filling_level, small_in_ready);

assert property (@(posedge clk) rst_n |->
    large_filling_level <= LARGE_DEPTH && large_in_ready == (large_filling_level != LARGE_DEPTH))
else $fatal(1, "Large FIFO has filling level %0d but in_ready %0d!",
    large_filling_level, large_in_ready);

assert property (@(posedge clk) disable iff (!rst_n)
    (!small_out_valid || small_filling_level != 0) &&
    (!large_out_valid || large_filling_level != 0))
else $fatal(1, "A FIFO is valid while it is empty!");
`endif
