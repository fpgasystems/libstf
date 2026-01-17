from coyote_test import constants, fpga_register, fpga_test_case
from typing import List
from unit_test.fpga_stream import StreamType
from libstf_utils.common import INTERRUPT_TRANSFER_SIZE_BITS
import math

class GlobalConfig:
    """
    A global configuration, which contains the system id, number of configurations, the 
    subconfigurations address spaces and ids.
    """
    
    def __init__(self, test_case: fpga_test_case.FPGATestCase):
        self._test_case = test_case
        self.system_id = None
        self.num_configs = None
        self._addr_spaces = None
        self._config_ids = None

    def init(self):
        """
        We initialize this lazily because the simulation has to be running already for read_register
        to return.
        """

        self.system_id   = self._test_case.read_register(0)
        self.num_configs = self._test_case.read_register(1)

        self._addr_spaces = [2 + self.num_configs] + [None for _ in range(self.num_configs)]
        self._config_ids = [None for _ in range(self.num_configs)]

        for i in range(self.num_configs):
            self._addr_spaces[i + 1] = self._test_case.read_register(2 + i)
            self._set_config_id(i, self._test_case.read_register(self._addr_spaces[i])) 

    def _set_config_id(self, config_idx: int, config_id: int):
        assert config_id not in self._config_ids

        self._config_ids[config_idx] = config_id

    def get_config_bounds(self, config_id: int):
        assert self.has_config(config_id)

        config_idx = self._config_ids.index(config_id)
        return (self._addr_spaces[config_idx], self._addr_spaces[config_idx + 1])
    
    def has_config(self, config_id: int):
        if self.system_id is None:
            self.init()

        return config_id in self._config_ids

# Most general configuration class
# Configures which stream is valid and the stream types
# -> Is extended by configurations for specific operators like filter or projection
class StreamConfig:
    def __init__(self, offset: int, stream_id: int, select: int, type: StreamType):
        """
        Creates a new configuration, which tells the FPGA to use the memory region starting from 
        vaddr and over size bytes to send the output of stream with id stream_id. Offset is the 
        start of the memory configuration registers. 
        """
        self.offset = offset
        self.stream_id = stream_id
        self.select = select
        self.type = type

    def to_register_configuration(self) -> List[fpga_register.vFPGARegister]:
        # Determine the id of the register
        select_reg_id = self.offset + 2 * self.stream_id
        type_reg_id  = self.offset + 2 * self.stream_id + 1

        return [
            fpga_register.vFPGARegister(
                select_reg_id,
                bytearray(self.select.to_bytes(4, constants.BYTE_ORDER)),
            ),
            fpga_register.vFPGARegister(
                type_reg_id,
                bytearray(self.type.value.to_bytes(4, constants.BYTE_ORDER)),
            ),
        ]


class MemConfig:
    ID = 0

    def __init__(self, global_config: GlobalConfig, stream_id: int, vaddr: int, size: int, bytes_per_fpga_transfer: int):
        """
        Creates a new configuration, which tells the FPGA to use the memory region starting from 
        vaddr and over size bytes to send the output of stream with id stream_id. GlobalConfig is 
        used to fetch the address space offset of this config. 
        """
        self.global_config = global_config
        self.stream_id = stream_id
        self.vaddr = vaddr
        self.size = size
        self.bytes_per_fpga_transfer = bytes_per_fpga_transfer
        self.offset = None
        self.buffer_size_bits = None

    def _to_bytearray(self, size: int, value: int) -> bytearray:
        """
        Ensures the value fits into size bits.
        Then, the id is prepended. Finally, the whole value
        will be converted to a bytearray with 8 bytes.
        """
        assert value <= pow(2, size) - 1, (
            f"Value {value} was out of range for the target of {size} bits"
        )
        return bytearray(value.to_bytes(8, constants.BYTE_ORDER))

    def to_register_configuration(self) -> List[fpga_register.vFPGARegister]:
        if self.offset is None:
            self.offset = self.global_config.get_config_bounds(MemConfig.ID)[0]
        
        assert self.vaddr < pow(2, constants.VADDR_BITS)
        assert self.size < pow(2, INTERRUPT_TRANSFER_SIZE_BITS)

        # Determine the id of the register
        reg_id = self.offset + self.stream_id

        transfer_bit_shift = int(math.log2(self.bytes_per_fpga_transfer))
        if self.buffer_size_bits is None:
            self.buffer_size_bits = INTERRUPT_TRANSFER_SIZE_BITS - transfer_bit_shift

        return [
            fpga_register.vFPGARegister(
                reg_id,
                self._to_bytearray(constants.VADDR_BITS + self.buffer_size_bits, 
                                   self.vaddr << self.buffer_size_bits | self.size >> transfer_bit_shift),
            )
        ]
