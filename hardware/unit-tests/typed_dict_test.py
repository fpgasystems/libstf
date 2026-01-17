import random
from coyote_test import fpga_test_case, fpga_register
from unit_test.fpga_stream import get_bytes_for_stream_type, Stream, StreamType
from libstf_utils.common import stream_type_to_libstf_type_t
from dict_test import DictExpression

class TypedDictTest(fpga_test_case.FPGATestCase):
    """
    These tests test the typed dictionary.
    """

    debug_mode = True
    verbose_logging = True
    alternative_vfpga_top_file = "vfpga_tops/typed_dict_test.sv"

    # Method that gets executed once per test case
    def setUp(self):
        super().setUp()
        self.expression: DictExpression = None

    def simulate_fpga(self):
        assert self.expression is not None, (
            "Cannot have dictionary test with empty dictionary expression!"
        )

        # Configuration
        for values in self.expression.values:
            stream_type = values.stream_type()
            assert get_bytes_for_stream_type(stream_type) in (4, 8), (
                "Only 32bit and 64bit columns are supported by dictionary"
            )
            type_reg = stream_type_to_libstf_type_t(stream_type)

            # 3 offset for global regs
            self.write_register(fpga_register.vFPGARegister(3, bytearray([type_reg]))) 

        # Set the input data
        for values in self.expression.values:
            self.set_stream_input(0, values)
        for ids in self.expression.get_ids():
            self.set_stream_input(1, ids)

        # Set the expected output data
        for results in self.expression.apply():
            self.set_expected_output(0, results)

        return super().simulate_fpga()

    def test_sequential_32bit(self):
        values = Stream(StreamType.UNSIGNED_INT_32, list(range(0, 500)))
        ids = [i for i in range(0, 500)]
        self.expression = DictExpression(
            [values],
            [ids]
        )

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_random_32bit(self):
        values = Stream(StreamType.UNSIGNED_INT_32, list(range(0, 500)))
        ids = [random.randint(0, 499) for _ in range(0, 1001)]
        self.expression = DictExpression(
            [values],
            [ids]
        )

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_sequential_64bit(self):
        values = Stream(StreamType.UNSIGNED_INT_64, list(range(0, 500)))
        ids = [i for i in range(0, 500)]
        self.expression = DictExpression(
            [values],
            [ids]
        )

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_random_64bit(self):
        values = Stream(StreamType.UNSIGNED_INT_64, list(range(0, 500)))
        ids = [random.randint(0, 499) for _ in range(0, 1001)]
        self.expression = DictExpression(
            [values],
            [ids]
        )

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()
    
    def test_sequential_32bit_twice(self):
        values_0 = Stream(StreamType.UNSIGNED_INT_32, list(range(0, 500)))
        values_1 = Stream(StreamType.UNSIGNED_INT_32, list(range(1, 501)))
        ids = [i for i in range(0, 500)]
        self.expression = DictExpression(
            [values_0, values_1],
            [ids, ids]
        )

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()
