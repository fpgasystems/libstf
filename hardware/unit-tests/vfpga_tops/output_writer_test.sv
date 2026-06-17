
// -- Tie-off unused interfaces and signals --------------------------------------------------------
always_comb sq_rd.tie_off_m();
always_comb cq_rd.tie_off_s();

// -- Fix clock and reset names --------------------------------------------------------------------
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

// -- Configuration --------------------------------------------------------------------------------
write_config_i write_configs[2](clk, rst_n);
read_config_i  read_configs [2](clk, rst_n);

GlobalConfig #(
    .SYSTEM_ID(0),
    .NUM_CONFIGS(2),
    .ADDR_SPACE_SIZES({N_STRM_AXI + 1, 4 * N_STRM_AXI + 1})
) inst_config (
    .clk(clk),
    .rst_n(rst_n),

    .axi_ctrl(axi_ctrl),

    .write_configs(write_configs),
    .read_configs(read_configs)
);

mem_config_i mem_config[N_STRM_AXI](clk, rst_n);
MemConfig #(
    .NUM_STREAMS(N_STRM_AXI)
) inst_mem_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[0]),
    .read_config(read_configs[0]),

    .out(mem_config)
);

// -- Profiling ------------------------------------------------------------------------------------

// We use this for profiling in the output buffer manager software example
data64_t perf_counters[4 * N_STRM_AXI];
data64_t write_regs[1];
GenericConfig #(
    .NUM_READ_REGISTERS(4 * N_STRM_AXI),
    .NUM_WRITE_REGISTERS(1)
) inst_generic_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[1]),
    .read_config(read_configs[1]),

    .in(perf_counters),
    .out(write_regs)
);

data64_t num_runs;
assign num_runs = write_regs[0];

for (genvar I = 0; I < N_STRM_AXI; I++) begin
    data64_t run_counter, n_run_counter;
    logic    is_stop;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            run_counter <= '0;
        end else begin
            run_counter <= n_run_counter;
        end
    end

    always_comb begin
        n_run_counter = run_counter;
        is_stop = 1'b0;

        if (axi_host_recv[I].tvalid && axi_host_recv[I].tlast && axi_host_recv[I].tready) begin
            if (run_counter == num_runs - 1) begin
                n_run_counter = '0;
                is_stop = 1'b1;
            end else begin
                n_run_counter = run_counter + 1;
            end
        end
    end

    stream_profile_i profile();
    assign profile.stop = is_stop;

    StreamProfiler inst_perf_counter (
        .clk(clk),
        .rst_n(rst_n),

        .last (axi_host_recv[I].tlast),
        .valid(axi_host_recv[I].tvalid),
        .ready(axi_host_recv[I].tready),

        .profile(profile)
    );

    assign perf_counters[4 * I]     = profile.counters.handshakes_cycles;
    assign perf_counters[4 * I + 1] = profile.counters.starved_cycles;
    assign perf_counters[4 * I + 2] = profile.counters.stalled_cycles;
    assign perf_counters[4 * I + 3] = profile.counters.idle_cycles;
end

// -- Output writer --------------------------------------------------------------------------------
AXI4S axi_host_recv[N_STRM_AXI](.aclk(clk), .aresetn(rst_n));
for (genvar I = 0; I < N_STRM_AXI; I++) begin
    `AXIS_ASSIGN(axis_host_recv[I], axi_host_recv[I]) // AXI4SR to AXI4S
end

OutputWriter inst_output_writer (
    .clk(aclk),
    .rst_n(rst_n),

    .sq_wr(sq_wr),
    .cq_wr(cq_wr),
    .notify(notify),

    .mem_config(mem_config),

    .data_in(axi_host_recv),
    .data_out(axis_host_send)
);
