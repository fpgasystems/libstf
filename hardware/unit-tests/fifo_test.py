import random
from typing import List
from coyote_test import fpga_test_case
from unit_test.fpga_stream import Stream, StreamType

# Number of 32-bit values per 512-bit data beat
VALUES_PER_BEAT = 16

class FIFOTest(fpga_test_case.FPGATestCase):
    """
    These tests test the MehdiFIFO. The vFPGA top passes the input through a FIFO with 2 entries
    and a FIFO with 16 entries and throttles the handshakes between them and at the output, so both
    FIFOs repeatedly fill up and run empty. The output has to equal the input.
    """

    alternative_vfpga_top_file = "vfpga_tops/fifo_test.sv"
    debug_mode = True
    verbose_logging = True

    def setUp(self):
        super().setUp()
        self.inputs: List[List[int]] = None

    def simulate_fpga(self):
        assert self.inputs is not None, "Cannot have FIFO test without input!"

        for input in self.inputs:
            self.set_stream_input(0, Stream(StreamType.UNSIGNED_INT_32, input))
            self.set_expected_output(0, Stream(StreamType.UNSIGNED_INT_32, input))

        return super().simulate_fpga()

    def test_single_beat(self):
        # Arrange
        self.inputs = [list(range(1, VALUES_PER_BEAT + 1))]

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_long_stream(self):
        # Arrange
        random.seed(42)
        self.inputs = [[random.getrandbits(32) for _ in range(0, 300 * VALUES_PER_BEAT)]]

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_multiple_streams(self):
        """
        Streams with partial last beats check that the keep and last signals pass the FIFOs.
        """
        # Arrange
        random.seed(42)
        self.inputs = [
            [random.getrandbits(32) for _ in range(0, random.randint(1, 40 * VALUES_PER_BEAT))]
            for _ in range(0, 10)
        ]

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()
