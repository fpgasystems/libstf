from typing import List
from coyote_test import fpga_test_case
from unit_test.fpga_stream import Stream, StreamType

# Number of 64-bit values per 512-bit data beat
VALUES_PER_BEAT = 8

def beat(value: int) -> List[int]:
    return [value] * VALUES_PER_BEAT

def null_beat() -> List[int]:
    return beat(0)

class NullBeatSuppressorTest(fpga_test_case.FPGATestCase):
    """
    These tests test the NullBeatSuppressor. The vFPGA top turns every input beat that only
    contains zeros into a null beat (keep == '0), which has to be removed from the output stream.
    """

    alternative_vfpga_top_file = "vfpga_tops/null_beat_suppressor_test.sv"
    debug_mode = True
    verbose_logging = True

    def setUp(self):
        super().setUp()
        self.inputs: List[List[int]] = None

    def simulate_fpga(self):
        assert self.inputs is not None, "Cannot have null beat suppressor test without input!"

        for input in self.inputs:
            # Set the input data
            self.set_stream_input(0, Stream(StreamType.UNSIGNED_INT_64, input))

            # Set the expected output data, i.e., the input without the all zero beats
            beats = [input[i:i + VALUES_PER_BEAT] for i in range(0, len(input), VALUES_PER_BEAT)]
            result = [v for b in beats if any(b) for v in b]
            self.set_expected_output(0, Stream(StreamType.UNSIGNED_INT_64, result))

        return super().simulate_fpga()

    def test_no_null_beats(self):
        # Arrange
        self.inputs = [list(range(1, 8 * VALUES_PER_BEAT + 4))]

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_null_beats_in_between(self):
        # Arrange
        self.inputs = [
            null_beat() + beat(1) + null_beat() + beat(2) + null_beat() + null_beat() + beat(3)
        ]

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_null_last_beat(self):
        """
        The last signal of a trailing null beat has to be moved to the last non-null beat.
        """
        # Arrange
        self.inputs = [beat(1) + beat(2) + null_beat()]

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_multiple_trailing_null_beats(self):
        # Arrange
        self.inputs = [beat(1) + null_beat() + null_beat() + null_beat()]

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_multiple_streams(self):
        # Arrange
        self.inputs = [
            beat(1) + null_beat() + beat(2) + null_beat(),
            null_beat() + beat(3),
            beat(4) + null_beat() + null_beat()
        ]

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()
