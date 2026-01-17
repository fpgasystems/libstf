from typing import List
from coyote_test import constants
from unit_test.fpga_stream import Stream, StreamType
from libstf_utils.output_writer_test_case import OutputWriterPerformanceTestCase, OutputWriterTestCase
from libstf_utils.memory_manager import FPGAOutputMemoryManager

MAX_NUMBER_STREAMS = constants.MAX_NUMBER_STREAMS
TRANSFER_SIZE_BYTES_OVERWRITE = "TRANSFER_SIZE_BYTES_OVERWRITE"

class OutputWriterTest(OutputWriterTestCase):
    """
    Tests the behavior of the FPGA-initiated transfers
    """

    alternative_vfpga_top_file = "vfpga_tops/output_writer_test.sv"
    debug_mode = True
    verbose_logging = True

    def setUp(self):
        super().setUp()
        # All data in this test is streamed through.
        # There is no actual computation happening
        # (due to the way the wiring is done)
        self.streams: List[Stream] = []

    def simulate_fpga(self):
        assert len(self.streams) > 0, "Cannot perform output test with 0 streams"

        self.simulate_fpga_non_blocking()
        
        # Set the input & output
        # We need to do this after starting the simulation non-blocking so the OutputWriterTestCase
        # can do configuration discovery and find the registers to write the buffer handles to.
        for id, stream in enumerate(self.streams):
            self.set_stream_input(id, stream)
            self.set_expected_output(id, stream)

        self.finish_fpga_simulation()

    def overwrite_memory_manager(self, allocation_size: int, transfer_size: int):
        """
        Overwrites the existing memory manager to have the new transfer & allocation size.
        Also sets those values for the simulation
        """
        self.memory_manager = FPGAOutputMemoryManager(
            self.get_io_writer(), 
            self.global_config, 
            allocation_size, 
            transfer_size
        )
        self.set_system_verilog_defines(
            {TRANSFER_SIZE_BYTES_OVERWRITE: str(transfer_size)}
        )

    def test_with_one_data_beat_per_transfer(self):
        # Arrange
        allocation_size = 512
        transfer_size = 64
        self.overwrite_memory_manager(allocation_size, transfer_size)

        total_data_bytes = 904
        self.streams.append(Stream(StreamType.UNSIGNED_INT_64, list(range(0, total_data_bytes // 8))))
        self.streams.append(Stream(StreamType.UNSIGNED_INT_64, list(range(0, total_data_bytes // 8))))

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_with_multiple_transfers_per_allocation(self):
        # Arrange
        allocation_size = 512
        transfer_size = 128
        self.overwrite_memory_manager(allocation_size, transfer_size)

        total_data_bytes = 904
        self.streams.append(Stream(StreamType.UNSIGNED_INT_64, list(range(0, total_data_bytes // 8))))
        self.streams.append(Stream(StreamType.UNSIGNED_INT_64, list(range(0, total_data_bytes // 8))))

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_with_one_transfer_per_allocation(self):
        # Arrange
        allocation_size = 64
        transfer_size = 64
        self.overwrite_memory_manager(allocation_size, transfer_size)

        total_data_bytes = 904
        self.streams.append(Stream(StreamType.UNSIGNED_INT_64, list(range(0, total_data_bytes // 8))))
        self.streams.append(Stream(StreamType.UNSIGNED_INT_64, list(range(0, total_data_bytes // 8))))

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_with_default_allocation_size(self):
        # Arrange
        total_data_bytes = 904
        self.streams.append(Stream(StreamType.UNSIGNED_INT_64, list(range(0, total_data_bytes // 8))))

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_with_half_data_beat_at_the_end(self):
        # Arrange
        allocation_size = 64
        transfer_size = 64
        self.overwrite_memory_manager(allocation_size, transfer_size)

        total_data_bytes = 92
        self.streams.append(Stream(StreamType.UNSIGNED_INT_64, list(range(0, total_data_bytes // 8))))

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_arbitration_full_streams(self):
        # Arrange
        allocation_size = 256
        transfer_size = 64
        self.overwrite_memory_manager(allocation_size, transfer_size)

        total_data_bytes = 4000
        for _ in range(0, MAX_NUMBER_STREAMS):
            self.streams.append(Stream(StreamType.UNSIGNED_INT_64, list(range(0, total_data_bytes // 8))))

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_very_large_input(self):
        # Arrange
        allocation_size = 3 * 4096
        transfer_size = 4096
        self.overwrite_memory_manager(allocation_size, transfer_size)

        total_data_bytes = 4096 * 10
        self.streams.append(Stream(StreamType.UNSIGNED_INT_64, list(range(0, total_data_bytes // 8))))

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()


class OutputWriterPerformanceTest(OutputWriterPerformanceTestCase):
    """
    Tests the performance of the FPGA-initiated transfers
    """
    alternative_vfpga_top_file = "vfpga_tops/output_writer_test.sv"
    debug_mode = True
    verbose_logging = True

    def setUp(self):
        super().setUp()
        # All data in this test is streamed through.
        # There is no actual computation happening
        # (due to the way the wiring is done)
        self.streams: List[Stream] = []

    def simulate_fpga(self):
        assert len(self.streams) > 0, "Cannot perform output test with 0 streams"

        self.simulate_fpga_non_blocking()

        # Set the input & output
        for id, stream in enumerate(self.streams):
            self.set_stream_input(id, stream)
            self.set_expected_output(id, stream)

        self.finish_fpga_simulation()

    def test_streaming_through_performance(self):
        # Arrange
        total_data_bytes = 2000
        for _ in range(0, MAX_NUMBER_STREAMS):
            self.streams.append(Stream(StreamType.UNSIGNED_INT_64, list(range(0, total_data_bytes // 8))))
        self.set_expected_avg_cycles_per_batch_for_all_streams(1.0)

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()
        self.assert_expected_performance()
    