import random
from unit_test.fpga_stream import get_bytes_for_stream_type, Stream, StreamType
from libstf_utils.configured_test_case import ConfiguredTestCase
from libstf_utils.fpga_configuration import StreamConfig
from dict_test import DictExpression

INT128_T = 6 # libstf type_t


class DictExpression128(DictExpression):
    """
    The 128 bit values are given as pairs of 64 bit values, the ids refer to the pairs. 32 bit values
    are taken as they are.
    """

    def apply(self):
        result = []
        for v, i in zip(self.values, self.ids):
            data = v.stream_data()
            if v.stream_type() == StreamType.UNSIGNED_INT_64:
                data = [x for id in i for x in data[2 * id:2 * id + 2]]
            else:
                data = [data[id] for id in i]
            result.append(Stream(v.stream_type(), data))
        return result


class TypedDictTest(ConfiguredTestCase):
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

    def configure(self):
        assert self.expression is not None, (
            "Cannot have dictionary test with empty dictionary expression!"
        )

        # Configuration
        stream_config = self.config.get_config(StreamConfig)
        for values in self.expression.values:
            stream_type = values.stream_type()
            assert get_bytes_for_stream_type(stream_type) in (4, 8), (
                "Only 32bit and 64bit columns are supported by dictionary"
            )
            if isinstance(self.expression, DictExpression128) and stream_type == StreamType.UNSIGNED_INT_64:
                stream_config.write_register(0, INT128_T)
            else:
                stream_config.enqueue_stream_config(0, stream_type)

        # Set the input data
        for values in self.expression.values:
            self.set_stream_input(0, values)
        for ids in self.expression.get_ids():
            self.set_stream_input(1, ids)

        # Set the expected output data
        for results in self.expression.apply():
            self.set_expected_output(0, results)

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

    def test_sequential_128bit(self):
        values = Stream(StreamType.UNSIGNED_INT_64, list(range(0, 1000)))
        ids = [i for i in range(0, 500)]
        self.expression = DictExpression128([values], [ids])

        self.simulate_fpga()

        self.assert_simulation_output()

    def test_random_128bit(self):
        values = Stream(StreamType.UNSIGNED_INT_64, list(range(0, 1000)))
        ids = [random.randint(0, 499) for _ in range(0, 1001)]
        self.expression = DictExpression128([values], [ids])

        self.simulate_fpga()

        self.assert_simulation_output()

    def test_128bit_twice(self):
        values_0 = Stream(StreamType.UNSIGNED_INT_64, list(range(0, 1000)))
        values_1 = Stream(StreamType.UNSIGNED_INT_64, list(range(1, 1001)))
        ids = [random.randint(0, 499) for _ in range(0, 300)]
        self.expression = DictExpression128([values_0, values_1], [ids, ids])

        self.simulate_fpga()

        self.assert_simulation_output()

    def test_128bit_then_32bit(self):
        values_0 = Stream(StreamType.UNSIGNED_INT_64, list(range(0, 1000)))
        values_1 = Stream(StreamType.UNSIGNED_INT_32, list(range(5, 505)))
        ids = [random.randint(0, 499) for _ in range(0, 300)]
        self.expression = DictExpression128([values_0, values_1], [ids, ids])

        self.simulate_fpga()

        self.assert_simulation_output()
