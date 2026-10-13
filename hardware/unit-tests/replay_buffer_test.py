from typing import Dict, List, Optional, Tuple
from unit_test import simulation_time
from unit_test.fpga_stream import Stream, StreamType
from libstf_utils.configured_test_case import ConfiguredTestCase
from libstf_utils.fpga_configuration import ReplayBufferConfig

# Number of 64-bit values per 512-bit data beat
VALUES_PER_BEAT = 8

# Transfer size of the ReplayBuffer in the vFPGA top during the unit tests
TRANSFER_SIZE = 128

def empty_stream() -> Stream:
    """
    The vFPGA top turns a beat of only zeros into a null beat, so this stream becomes empty.
    """
    return Stream(StreamType.UNSIGNED_INT_64, [0] * VALUES_PER_BEAT)

class ReplayBufferTest(ConfiguredTestCase):
    """
    Tests the behavior of the HBM caching of AXI streams.

    The vFPGA top uses a transfer size of 128 bytes. The subclasses below run the same tests with
    backpressure on the output and with ring buffers that are small enough to wrap around and fill
    up.
    """

    alternative_vfpga_top_file = "vfpga_tops/replay_buffer_test.sv"
    debug_mode = True
    verbose_logging = True

    throttle_output = False
    # Size of the card memory ring buffer in bytes. None makes it large enough for all streams.
    ring_buffer_size: Optional[int] = None

    def setUp(self):
        super().setUp()
        # Data to write to the HBM, sequentially as provided in this list, and how often each stream
        # is read
        self.writes: List[Tuple[Stream, int]] = []

    def add_write(self, stream: Stream, num_reads: int = 1):
        self.writes.append((stream, num_reads))

    def simulate_fpga(self):
        assert len(self.writes) > 0, "Cannot perform output test with 0 writes"

        defines: Dict[str, str] = {
            "REPLAY_BUFFER_TRANSFER_SIZE": str(TRANSFER_SIZE),
            "REPLAY_BUFFER_TEST_EMPTY_STREAMS": "1",
        }
        if self.throttle_output:
            defines["REPLAY_BUFFER_THROTTLE"] = "1"
        self.set_system_verilog_defines(defines)

        # The configuration discovery alone takes longer than the default simulation time
        self.overwrite_simulation_time(simulation_time.SimulationTime.till_finished())

        return super().simulate_fpga()

    def configure(self):
        ring_buffer_size = self.ring_buffer_size
        if ring_buffer_size is None:
            # Every stream starts a new transfer in the worst case
            ring_buffer_size = sum(
                len(stream.data_to_bytearray()) + TRANSFER_SIZE for (stream, _) in self.writes
            )

        replay_buffer_config = self.config.get_config(ReplayBufferConfig)
        ring_buffer_vaddr = self.get_io_writer().allocate_next_free_sim_memory(ring_buffer_size)
        replay_buffer_config.configure_ring_buffer(0, ring_buffer_vaddr, ring_buffer_size)

        assert replay_buffer_config.transfer_size == TRANSFER_SIZE
        assert len(self.writes) <= replay_buffer_config.maximum_num_enqueued_streams, (
            "The test enqueues more numbers of reads than the replay buffer can hold"
        )
        for (_, num_reads) in self.writes:
            replay_buffer_config.enqueue_num_reads(0, num_reads)

        for (stream, _) in self.writes:
            self.set_stream_input(0, stream)

        # Every read produces an output stream. The host does not receive anything for empty streams.
        for (stream, num_reads) in self.writes:
            if any(stream.stream_data()):
                for _ in range(num_reads):
                    self.set_expected_output(0, stream)

        # The simulation counts all completed writes, including the writes of the replay buffer to the
        # card memory. Without them, the test would end the input before all outputs were written.
        for (stream, _) in self.writes:
            if any(stream.stream_data()):
                num_bytes = len(stream.data_to_bytearray())
                self._expected_completed_write_transfers += (num_bytes + TRANSFER_SIZE - 1) // TRANSFER_SIZE

    def test_one_write_read(self):
        l = 128
        self.add_write(Stream(StreamType.UNSIGNED_INT_64, list(range(0, l))))

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_two_write_read(self):
        self.add_write(Stream(StreamType.UNSIGNED_INT_64, list(range(0, 64))))
        self.add_write(Stream(StreamType.UNSIGNED_INT_64, list(range(0, 23))))

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_many_small_write_read(self):
        for l in range(10, 30):
            self.add_write(Stream(StreamType.UNSIGNED_INT_8, list(range(0, l))))

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_replay(self):
        """
        Streams that are read multiple times appear as often at the output, one after another. All
        streams fit into a single transfer in every configuration.
        """
        self.add_write(Stream(StreamType.UNSIGNED_INT_64, list(range(0, 16))), 2)
        self.add_write(Stream(StreamType.UNSIGNED_INT_64, list(range(100, 110))), 1)
        self.add_write(Stream(StreamType.UNSIGNED_INT_64, list(range(200, 213))), 3)
        self.add_write(Stream(StreamType.UNSIGNED_INT_8, list(range(1, 51))), 2)

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_replay_multi_transfer(self):
        """
        A stream of multiple transfers that is read multiple times. Its replays are read as whole
        segments, so the last signal must only be set on the final beat of the final transfer.
        """
        if self.ring_buffer_size is not None and self.ring_buffer_size < 4 * TRANSFER_SIZE:
            self.skipTest("The ring buffer is too small for a stream of three transfers")

        self.add_write(Stream(StreamType.UNSIGNED_INT_64, list(range(0, 10))), 1)
        # Three transfers of 128, 128, and 64 bytes
        self.add_write(Stream(StreamType.UNSIGNED_INT_64, list(range(100, 140))), 2)
        self.add_write(Stream(StreamType.UNSIGNED_INT_64, list(range(200, 205))), 1)

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_write_ahead(self):
        """
        The writer keeps writing the next streams while the reader replays a stream, so many written
        streams wait for the reader at once.
        """
        self.add_write(Stream(StreamType.UNSIGNED_INT_64, list(range(0, 16))), 4)
        for l in range(20, 32):
            self.add_write(Stream(StreamType.UNSIGNED_INT_8, list(range(1, l))), 1)
        self.add_write(Stream(StreamType.UNSIGNED_INT_64, list(range(500, 510))), 2)

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_replay_empty_streams(self):
        """
        An empty stream that is read multiple times results in multiple empty streams.
        """
        self.add_write(empty_stream(), 3)
        self.add_write(Stream(StreamType.UNSIGNED_INT_64, list(range(1, 6))), 2)
        self.add_write(empty_stream(), 1)
        self.add_write(empty_stream(), 2)
        self.add_write(Stream(StreamType.UNSIGNED_INT_64, list(range(1, 10))), 1)

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_empty_streams(self):
        """
        An empty stream must not stall the buffer and must be reproduced at the output.
        """
        self.add_write(empty_stream())
        self.add_write(Stream(StreamType.UNSIGNED_INT_64, list(range(0, 40))))
        self.add_write(empty_stream())
        self.add_write(empty_stream())
        self.add_write(Stream(StreamType.UNSIGNED_INT_64, list(range(0, 17))))

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()


class ReplayBufferBackpressureTest(ReplayBufferTest):
    """
    The output is backpressured, so data is still held inside the reader when the next transfer of
    the link is accepted.
    """

    throttle_output = True


class ReplayBufferSmallRingTest(ReplayBufferTest):
    """
    The ring buffer only fits two transfers and some bytes. So the writer has to wait for the reader
    to release memory and skip the end of the ring buffer when a transfer does not fit.
    """

    ring_buffer_size = 2 * TRANSFER_SIZE + 64


class ReplayBufferSmallRingBackpressureTest(ReplayBufferTest):
    """
    Like ReplayBufferSmallRingTest, but with a slow reader and a ring buffer that fits a stream of
    three transfers that is read multiple times.
    """

    throttle_output = True
    ring_buffer_size = 4 * TRANSFER_SIZE + 64


class ReplayBufferWrappingReplayTest(ReplayBufferTest):
    """
    The ring buffer fits three transfers. This makes a stream that is read multiple times wrap
    around the end of the ring buffer.
    """

    ring_buffer_size = 3 * TRANSFER_SIZE

    def test_wrapping_replay(self):
        # Occupies [0, 192), so the next stream starts at 192
        self.add_write(Stream(StreamType.UNSIGNED_INT_64, list(range(0, 24))), 1)
        # Occupies [192, 320) and, after skipping [320, 384), [0, 128)
        self.add_write(Stream(StreamType.UNSIGNED_INT_64, list(range(1000, 1032))), 2)
        # Has to wait until the previous stream was read twice
        self.add_write(Stream(StreamType.UNSIGNED_INT_8, list(range(1, 101))), 2)
        # A stream that is read once can be larger than the ring buffer
        self.add_write(Stream(StreamType.UNSIGNED_INT_64, list(range(0, 80))), 1)

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()
