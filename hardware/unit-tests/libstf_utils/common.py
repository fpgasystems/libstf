from coyote_test import constants
from unit_test.fpga_stream import StreamType

# The interrupt value has 32 bits.
# We need 3 bits for the stream indicator and 1 bit for the last signal.
# This leaves 28 bits for the maximum output size per allocation.
INTERRUPT_STREAM_ID_BITS = 3
INTERRUPT_TRANSFER_SIZE_BITS = 28
INTERRUPT_LAST_BITS = 1
MAXIMUM_HOST_MEMORY_ALLOCATION_SIZE_BYTES = pow(2, INTERRUPT_TRANSFER_SIZE_BITS) - 1

# Due to the interrupt stream indicator, the maximum number of
# supported streams with FPGA transfers is limited
MAX_SUPPORTED_N_STREAMS = pow(2, INTERRUPT_STREAM_ID_BITS)

#
# Assertions 
#
assert constants.MAX_NUMBER_STREAMS % 2 == 0, "The number of streams needs to be divisible by two for the design to work!"
assert constants.MAX_NUMBER_STREAMS <= MAX_SUPPORTED_N_STREAMS, (
    "Due to limitations in the FPGA-initiated transfers, we can currently support " + 
    f"at most {MAX_SUPPORTED_N_STREAMS} streams. Configuration had " + 
    f"{constants.MAX_NUMBER_STREAMS} streams"
)
assert INTERRUPT_STREAM_ID_BITS + INTERRUPT_TRANSFER_SIZE_BITS + INTERRUPT_LAST_BITS <= 32, (
    "The sum of all the bits in the interrupt value cannot be larger "
    + "than the available data size of 32 bit."
)

def stream_type_to_libstf_type_t(data_type: StreamType) -> int:
    if data_type == StreamType.UNSIGNED_INT_8 or data_type == StreamType.SIGNED_INT_8:
        return 0
    elif data_type == StreamType.SIGNED_INT_32 or data_type == StreamType.UNSIGNED_INT_32:
        return 1
    elif data_type == StreamType.SIGNED_INT_64 or data_type == StreamType.UNSIGNED_INT_64:
        return 2
    elif data_type == StreamType.FLOAT_32:
        return 3
    elif data_type == StreamType.FLOAT_64:
        return 4
    else:
        raise TypeError(f"The provided StreamType cannot be cast to libstf's type_t: {repr(data_type)}")
