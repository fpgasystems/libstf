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
        self.streams: List[List[int]] = None

    def simulate_fpga(self):
        """
        Drives `self.input` as one stream, or every list in `self.streams` as its own stream (each ends
        with last) directly after each other.
        """
        streams = self.streams if self.streams is not None else [self.input]
        assert all(s is not None for s in streams), (
            "Cannot have lookahead test without input!"
        )

        for stream in streams:
            self.set_stream_input(0, Stream(StreamType.UNSIGNED_INT_8, stream))
            self.set_expected_output(0, Stream(StreamType.UNSIGNED_INT_8, stream))

            # One record per beat: the first 3 bytes of the next beat of the same stream, padded with 0,
            # and a mask of the valid ones. The last beat of a stream previews nothing, even if the next
            # stream is already waiting.
            result = []
            for word_idx in range(ceil(len(stream) / 64)):
                preview = stream[(word_idx + 1) * 64:(word_idx + 1) * 64 + 3]
                result.extend(preview + [0] * (3 - len(preview)) + [(1 << len(preview)) - 1])
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

    def test_back_to_back_streams(self):
        self.streams = [
            [i % 256 for i in range(200)],
            [(i * 7) % 256 for i in range(300)],
        ]

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_single_full_beat_after_last(self):
        # The second stream is a single beat, so it is also the last beat of its stream. The third one
        # catches a duplicated or stuck beat, which would otherwise only show after the simulation ends.
        self.streams = [
            [i % 256 for i in range(128)],
            [(255 - i) % 256 for i in range(64)],
            [(i * 5) % 256 for i in range(130)],
        ]

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_single_partial_beat_after_last(self):
        self.streams = [
            [i % 256 for i in range(100)],
            [(i * 3) % 256 for i in range(10)],
            [(i * 11) % 256 for i in range(70)],
        ]

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_many_short_streams(self):
        # Single beat streams in between, and 65 to 67 bytes, where the last beat holds at most as many
        # bytes as the lookahead
        lengths = [1, 65, 14, 66, 64, 67, 79, 1, 92, 130, 200, 64]
        self.streams = [[(s * 16 + i) % 256 for i in range(n)] for s, n in enumerate(lengths)]

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()
