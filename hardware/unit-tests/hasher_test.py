import random
from typing import List
from coyote_test import fpga_test_case
from unit_test.fpga_stream import Stream, StreamType
from libstf_utils.hashing import murmur32

class HasherTest(fpga_test_case.FPGATestCase):
    """
    These tests test the StreamHasher.
    """

    alternative_vfpga_top_file = "vfpga_tops/hasher_test.sv"

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
        self.set_stream_input(0, Stream(StreamType.UNSIGNED_INT_32, self.input))

        # Set the expected output data
        result = []
        for e in self.input:
            result.append(murmur32(e))
        self.set_expected_output(0, Stream(StreamType.UNSIGNED_INT_32, result))

        return super().simulate_fpga()

    def test_sequential(self):
        self.input = [i for i in range(0, 500)]

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_random(self):
        random.seed(42)
        self.input = [random.getrandbits(32) for _ in range(0, 1001)]

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()
