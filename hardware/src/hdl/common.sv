`timescale 1ns / 1ps

package libstf;

import lynxTypes::VADDR_BITS;
import lynxTypes::LEN_BITS;

// -- Constants ------------------------------------------------------------------------------------

// This value describes the maximum size in Bytes of one transfer of the `OutputWriter`. The  buffer
// allocated for the output by the host should be a multiple of this size. The overwrite value is
// only used on tests to trigger specific conditions.
`ifdef TRANSFER_SIZE_BYTES_OVERWRITE
    localparam integer TRANSFER_SIZE_BYTES = `TRANSFER_SIZE_BYTES_OVERWRITE;
`else
    // This value is chosen as it is the smallest transfer size to get peak PCIe throughput in the 
    // perf_fpga example. See: 
    //      https://github.com/fpgasystems/Coyote/tree/master/examples/07_perf_fpga
    localparam integer TRANSFER_SIZE_BYTES = 65536;
`endif

// The maximum buffer size for the `OutputWriter` (2**28 - 1 = 256 MiB - 1 Byte). This limitation
// comes from the 32 bits we have available for interrupt values.
localparam integer MAXIMUM_BUFFER_SIZE = 28;
localparam integer BUFFER_SIZE_BITS = 28 - $clog2(TRANSFER_SIZE_BYTES);

localparam GENERIC_CONFIG_ID = -1;

localparam MEM_CONFIG_ID = 0;
localparam MAXIMUM_NUM_ENQUEUED_BUFFERS = 256;

localparam STREAM_CONFIG_ID = 1;

// -- Typedef --------------------------------------------------------------------------------------
typedef logic[7:0]  data8_t;
typedef logic[15:0] data16_t;
typedef logic[31:0] data32_t;
typedef logic[63:0] data64_t;

typedef logic signed [7:0]  int8_t;
typedef logic signed [15:0] int16_t;
typedef logic signed [31:0] int32_t;
typedef logic signed [63:0] int64_t;

// Width matches the Coyote req_t.len field this size ultimately drives.
typedef logic[LEN_BITS - 1:0] size_t;

typedef enum logic[2:0] {
    BYTE_T,
    INT32_T,
    INT64_T,
    FLOAT_T,
    DOUBLE_T
} type_t;

// Aggregated StreamProfiler counters for a single stream.
typedef struct packed {
    data64_t handshakes_cycles;
    data64_t starved_cycles;
    data64_t stalled_cycles;
    data64_t idle_cycles;
} stream_profile_t;

// MemConfig
typedef logic[VADDR_BITS - 1:0]       vaddress_t; // Cannot be vaddr_t because of conflict with Coyote sim
typedef logic[BUFFER_SIZE_BITS - 1:0] buffer_size_t;

typedef struct packed {
    vaddress_t    vaddr;
    buffer_size_t size;
} buffer_t;

// StreamConfig
typedef data8_t select_t;

typedef struct packed {
    type_t   data_type;
    select_t select;
} stream_conf_t;

// Determines whether a pipeline register should be placed on pipe `pos` (1..num_stages) when
// distributing `register_levels` registers across `num_stages` pipeline stages. A register sits at
// `pos` whenever the running count of registers that should exist by `pos` increments. This places
// exactly min(register_levels, num_stages) registers, evenly distributed, with the last always
// after the final stage. register_levels == 0 => none.
function automatic bit PUT_REGISTER_AT(int pos, int num_stages, int register_levels);
    if (register_levels == 0) return 1'b0;
    return ((pos * register_levels) / num_stages) != (((pos - 1) * register_levels) / num_stages);
endfunction

// Constant function to return the bit width of type_t types
function automatic int GET_TYPE_WIDTH(type_t data_type);
    case (data_type)
        BYTE_T: begin
            return 8;
        end
        INT32_T, FLOAT_T: begin
            return 32;
        end
        INT64_T, DOUBLE_T: begin
            return 64;
        end
        default: begin
            return 0;
        end
    endcase
endfunction

endpackage
