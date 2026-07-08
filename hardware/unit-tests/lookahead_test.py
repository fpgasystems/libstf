import random
from typing import List
from coyote_test import fpga_test_case
from unit_test.fpga_stream import Stream, StreamType
from libstf_utils.hashing import murmur32
from math import ceil

class LookaheadTest(fpga_test_case.FPGATestCase):
    """
    These tests test the Lookahead.
    """

    alternative_vfpga_top_file = "vfpga_tops/data_lookahead_test.sv"

    debug_mode = True
    verbose_logging = True

    # Method that gets executed once per test case
    def setUp(self):
        super().setUp()
        self.input: List[int] = None

    def simulate_fpga(self):
        assert self.input is not None, (
            "Cannot have hasher test without input!"
        )

        # Set the input data
        self.set_stream_input(0, Stream(StreamType.UNSIGNED_INT_8, self.input))
        self.set_expected_output(0, Stream(StreamType.UNSIGNED_INT_8, self.input))

        result = []
        for word_idx in range(ceil(len(self.input) / 64) - 1):
            result.extend(
                [
                    self.input[word_idx * 64 + 64],
                    self.input[word_idx * 64 + 65],
                    self.input[word_idx * 64 + 66]
                ]
            )
        self.set_expected_output(1, Stream(StreamType.UNSIGNED_INT_8, result))

        return super().simulate_fpga()

    def test_basic(self):
        TEST_SIZE = 512
        self.input = [i % 256 for i in range(TEST_SIZE)]

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_single_beat(self):
        TEST_SIZE = 64
        self.input = [i % 256 for i in range(TEST_SIZE)]

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()
