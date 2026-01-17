# Small extension to the FPGATestCase classes with behavior specific to 
# tests that use the libstf configuration utils.
from coyote_test import (
    fpga_test_case
)
from libstf_utils.fpga_configuration import GlobalConfig


class ConfiguredTestCase(fpga_test_case.FPGATestCase):
    """
    This class provides all the needed extensions for the FPGATestCases. It does configuration 
    discovery after the simulation starts. With this test case, do not use simulate_fpga(). Use
    simulate_fpga_non_blocking() and finish_fpga_simuation(). The simulation has to have started 
    before the configuration discovery initializes the GlobalConfig because it uses blocking 
    configuration register reads.
    """

    def setUp(self):
        super().setUp()

        self.global_config = GlobalConfig(self)

    def simulate_fpga(self):
        raise NotImplementedError("simulate_fpga() is not supported when using a test case with a configuration")
