import random
from coyote_test import fpga_test_case
from typing import List
from unit_test.fpga_stream import Stream, StreamType

class NormalizerExpression:
    def __init__(
        self,
        bitmasks: List[List[bool]]
    ):
        # Check that bitmask lengths is a multiple of the number of Bytes per databeat
        for bitmask in bitmasks:
            assert len(bitmask) % 64 == 0

        self.bitmasks = bitmasks
    
    def apply(self) -> List[Stream]:
        """
        Returns the result column
        """
        result = []
        for bitmask in self.bitmasks:
            data = [i % 64 for i in range(len(bitmask)) if bitmask[i]]
            result.append(Stream(StreamType.UNSIGNED_INT_8, data))
        return result
    
    def get_bitmasks(self) -> List[Stream]:
        result = []
        for bitmask in self.bitmasks:
            mask = 0
            data = []
            for i, bit in enumerate(bitmask):
                idx = i % 64
                mask = int(bit) << idx | mask
                if idx == 63:
                    data += [mask] + [0] * 7
                    mask = 0
            result.append(Stream(StreamType.UNSIGNED_INT_64, data))
        return result

class NormalizerTest(fpga_test_case.FPGATestCase):
    alternative_vfpga_top_file = "vfpga_tops/normalizer_test.sv"
    debug_mode = True
    verbose_logging = True

    def setUp(self):
        super().setUp()
        self.expression: NormalizerExpression = None

    def simulate_fpga(self):
        assert self.expression is not None, (
            "Cannot have normalizer test with empty normalizer expression!"
        )

        # Set the input data
        for bitmask in self.expression.get_bitmasks():
            self.set_stream_input(0, bitmask)

        # Set the expected output data
        for results in self.expression.apply():
            self.set_expected_output(0, results)

        return super().simulate_fpga()

    def test_first_two_elements(self):
        # Arrange
        bitmask = [
            True, True
        ] + [False] * 62
        self.expression = NormalizerExpression([bitmask])
    
        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_all_elements(self):
        # Arrange
        bitmask = [True] * 64 * 4
        self.expression = NormalizerExpression([bitmask])
    
        # Act
        self.simulate_fpga()
        
        # Assert
        self.assert_simulation_output()

    def test_every_second_element(self):
        # Arrange
        bitmask = [False, True] * 64 * 3
        self.expression = NormalizerExpression([bitmask])
    
        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_random(self):
        # Arrange
        bitmask = [bool(random.getrandbits(1)) for _ in range(64 * 10)]
        self.expression = NormalizerExpression([bitmask])
    
        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_multiple(self):
        # Arrange
        bitmasks = [[bool(random.getrandbits(1)) for _ in range(64 * random.randint(3, 8))] for _ in range(3)]
        self.expression = NormalizerExpression(bitmasks)
    
        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()
