from itertools import repeat
import random
from typing import List
from coyote_test import fpga_test_case, fpga_performance_test_case, fpga_register
from unit_test import simulation_time
from unit_test.fpga_stream import get_bytes_for_stream_type, Stream, StreamType
from libstf_utils.common import stream_type_to_libstf_type_t

class DictExpression:
    def __init__(
        self,
        values: List[Stream],
        ids: List[List[int]],
    ):
        assert len(values) == len(ids)
        for v, i in zip(values, ids):
            assert len(i) > 0
            assert max(i) < len(v.stream_data())

        self.values = values
        self.ids = ids
    
    def apply(self) -> List[Stream]:
        """
        Returns the result column
        """
        result = []
        for v, i in zip(self.values, self.ids):
            data = [v.stream_data()[id] for id in i]
            result.append(Stream(v.stream_type(), data))
        return result
    
    def get_ids(self):
        result = []
        for i in self.ids:
            result.append(Stream(StreamType.UNSIGNED_INT_32, i))
        return result

class DictTestMixin():
    alternative_vfpga_top_file = "vfpga_tops/dict_test.sv"

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

        self.overwrite_simulation_time(simulation_time.SimulationTime.till_finished())
        return super().simulate_fpga()

class DictTest(DictTestMixin, fpga_test_case.FPGATestCase):
    """
    These tests test the dictionary.
    """

    debug_mode = True
    verbose_logging = True

    def test_sequential_32bit_once(self):
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

    def test_random_32bit_one(self):
        random.seed(42)

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
        random.seed(42)

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

    def test_duplicate_32bit_full(self):
        values = Stream(StreamType.UNSIGNED_INT_32, list(range(0, 50)))
        ids = [j for i in range(0, 50) for j in repeat(i, 8)]
        self.expression = DictExpression(
            [values],
            [ids]
        )

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

    def test_duplicate_32bit_odd(self):
        values = Stream(StreamType.UNSIGNED_INT_32, list(range(0, 100)))
        ids = [j for i in range(0, 100) for j in repeat(i, 3)]
        self.expression = DictExpression(
            [values],
            [ids]
        )

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()

class DictPerformanceTest(DictTestMixin, fpga_performance_test_case.FPGAPerformanceTestCase):
    debug_mode = True
    verbose_logging = True

    def test_sequential_64bit(self):
        NUM_VALUES = 500
        values = Stream(StreamType.UNSIGNED_INT_64, list(range(0, NUM_VALUES)))
        ids = [i % NUM_VALUES for i in range(0, 4000)]
        self.expression = DictExpression(
            [values],
            [ids]
        )

        # Perfect performance
        self.set_expected_avg_cycles_per_batch(0, len(ids) / NUM_VALUES)

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()
        self.assert_expected_performance()

    def test_random_64bit(self):
        random.seed(42)
        
        NUM_VALUES = 500
        values = Stream(StreamType.UNSIGNED_INT_64, list(range(0, NUM_VALUES)))
        ids = [random.randint(0, NUM_VALUES - 1) for _ in range(0, 4000)]
        self.expression = DictExpression(
            [values],
            [ids]
        )

        # We expect about 10% overhead from collisions
        self.set_expected_avg_cycles_per_batch(0, (len(ids) / NUM_VALUES) * 1.1)

        # Act
        self.simulate_fpga()

        # Assert
        self.assert_simulation_output()
        self.assert_expected_performance()
