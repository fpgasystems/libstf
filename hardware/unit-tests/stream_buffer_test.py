from typing import List
from coyote_test import constants, fpga_test_case
from unit_test.fpga_stream import Stream, StreamType

MAX_NUMBER_STREAMS = constants.MAX_NUMBER_STREAMS
TRANSFER_SIZE_BYTES_OVERWRITE = "TRANSFER_SIZE_BYTES_OVERWRITE"

class StreamBufferTest(fpga_test_case.FPGATestCase):
    """
    Tests the behavior of the HBM caching of AXI streams.
    """

    alternative_vfpga_top_file = "vfpga_tops/stream_buffer_test.sv"
    debug_mode = True
    verbose_logging = True

    def setUp(self):
        super().setUp()
        # Data to write to the HBM, sequentially as provided in this list
        self.writes: List[Stream] = []

    def simulate_fpga(self):
        card_allocation_size = 256 * 1024 * 1024
        assert len(self.writes) > 0, "Cannot perform output test with 0 writes"
        
        for stream in self.writes:
            self.set_stream_input(0, stream)

        # NOTE: it is important that the expected outputs are set after the inputs
        # as this affects the order of the mappings, which in turn affects the mappings
        # on the card memory, which MUST match the ones on the host input.
        #
        # If this is not the case, the writes would be unaligned with the allocated
        # memory segments, and even if the memory region overall is allocated,
        # it would be split in different segments, thus raising an exception:
        #
        # stream_simulation.svh:129: CARD[0]: No segment found to write data to in memory.
        #
        for stream in self.writes:
            self.set_expected_output(0, stream)

        return super().simulate_fpga()

    def test_one_write_read(self):
        l = 128
        self.writes.append(Stream(StreamType.UNSIGNED_INT_64, list(range(0, l))))

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_two_write_read(self):
        self.writes.append(Stream(StreamType.UNSIGNED_INT_64, list(range(0, 64))))
        self.writes.append(Stream(StreamType.UNSIGNED_INT_64, list(range(0, 23))))

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_many_small_write_read(self):
        for l in range(10, 30):
            self.writes.append(Stream(StreamType.UNSIGNED_INT_8, list(range(0, l))))

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()
