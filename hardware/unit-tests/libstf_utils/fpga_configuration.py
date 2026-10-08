# Python counterpart of software/libstf/configuration.hpp. Keep the register encodings in sync with
# the C++ implementation and the hardware in hardware/src/hdl/config.
from coyote_test import constants, fpga_register, fpga_test_case
from typing import Dict, List, Optional, Type, TypeVar
from unit_test.fpga_stream import StreamType
from libstf_utils.common import INTERRUPT_TRANSFER_SIZE_BITS
import math
import threading

REGISTER_BITS = 64

T = TypeVar("T", bound="Config")

def stream_type_to_libstf_type_t(data_type: StreamType) -> int:
    if data_type == StreamType.UNSIGNED_INT_8 or data_type == StreamType.SIGNED_INT_8:
        return 0
    elif data_type == StreamType.SIGNED_INT_32 or data_type == StreamType.UNSIGNED_INT_32:
        return 1
    elif data_type == StreamType.SIGNED_INT_64 or data_type == StreamType.UNSIGNED_INT_64:
        return 2
    elif data_type == StreamType.FLOAT_32:
        return 3
    elif data_type == StreamType.FLOAT_64:
        return 4
    else:
        raise TypeError(f"The provided StreamType cannot be cast to libstf's type_t: {repr(data_type)}")


def register(addr: int, value: int) -> fpga_register.vFPGARegister:
    """
    Creates a register write of the given value to the given absolute address.
    """
    assert 0 <= value < pow(2, REGISTER_BITS), (
        f"Value {value} does not fit into a {REGISTER_BITS} bit configuration register"
    )
    return fpga_register.vFPGARegister(
        addr, bytearray(value.to_bytes(REGISTER_BITS // 8, constants.BYTE_ORDER))
    )


class RegisterAccess:
    """
    Reads and writes absolute configuration registers of a test case. Reads are blocking, so the
    simulation has to be running. If a stop event is set, reads are aborted once it is raised, e.g.,
    because the simulation failed to compile, instead of blocking forever.
    """

    def __init__(self, test_case: fpga_test_case.FPGATestCase):
        self._test_case = test_case
        self.stop_event: Optional[threading.Event] = None

    def read(self, addr: int) -> int:
        value = self._test_case.read_register(addr, self.stop_event)
        if value is None:
            raise RuntimeError(
                f"Simulation stopped before configuration register {addr} could be read"
            )
        return value

    def write(self, addr: int, value: int):
        self._test_case.write_register(register(addr, value))


class Config:
    """
    Base class of all sub-configurations. All register addresses are relative to the start of the
    configuration's address space. Register 0 always contains the ID of the configuration.
    """

    ID: int = None

    def __init__(self, registers: RegisterAccess, addr_offset: int, num_regs: int):
        self._registers = registers
        self.addr_offset = addr_offset
        self.num_regs = num_regs

    def read_register(self, addr: int) -> int:
        assert addr < self.num_regs, (
            f"Register {addr} is out of bounds for {type(self).__name__} with {self.num_regs} registers"
        )
        return self._registers.read(self.addr_offset + addr)

    def write_register(self, addr: int, value: int):
        assert addr < self.num_regs, (
            f"Register {addr} is out of bounds for {type(self).__name__} with {self.num_regs} registers"
        )
        self._registers.write(self.addr_offset + addr, value)


class GlobalConfig:
    """
    The global configuration, which contains the system id, number of configurations, the
    sub-configurations' address spaces and ids. The sub-configurations are discovered by reading the
    global registers, which requires the simulation to be running.
    """

    def __init__(self, test_case: fpga_test_case.FPGATestCase):
        self._registers = RegisterAccess(test_case)
        self.system_id: Optional[int] = None
        self._config_ids: List[int] = None
        self._config_bounds: List[int] = None
        self._configs: Dict[int, Config] = {}

    def discover(self, stop_event: Optional[threading.Event] = None):
        """
        Reads the global registers. Reads are aborted once the optional stop_event is raised. This
        is called lazily on first use if it was not called explicitly.
        """
        self._registers.stop_event = stop_event

        self.system_id = self._registers.read(0)
        num_configs    = self._registers.read(1)

        self._config_bounds = [2 + num_configs]
        self._config_ids    = []

        for i in range(num_configs):
            self._config_bounds.append(self._registers.read(2 + i))

            config_id = self._registers.read(self._config_bounds[i])
            assert config_id not in self._config_ids, (
                f"Configuration ID {config_id} is present multiple times in the design"
            )
            self._config_ids.append(config_id)

    def _ensure_discovered(self):
        if self.system_id is None:
            self.discover()

    def has_config(self, config_id: int) -> bool:
        self._ensure_discovered()
        return config_id in self._config_ids

    def get_config_bounds(self, config_id: int):
        assert self.has_config(config_id), f"Design has no configuration with ID {config_id}"

        config_idx = self._config_ids.index(config_id)
        return (self._config_bounds[config_idx], self._config_bounds[config_idx + 1])

    def get_config(self, config_type: Type[T]) -> T:
        """
        Returns the sub-configuration of the given type, e.g., get_config(MemConfig).
        """
        if config_type.ID not in self._configs:
            assert self.has_config(config_type.ID), (
                f"Design has no configuration {config_type.__name__} (ID={config_type.ID})"
            )
            (lower, upper) = self.get_config_bounds(config_type.ID)
            self._configs[config_type.ID] = config_type(self._registers, lower, upper - lower)

        return self._configs[config_type.ID]


class MemConfig(Config):
    """
    Configures the buffers the OutputWriter writes the output streams to.
    """

    ID = 0

    def __init__(self, registers: RegisterAccess, addr_offset: int, num_regs: int):
        super().__init__(registers, addr_offset, num_regs)
        self.num_streams = self.read_register(1)
        self.maximum_num_enqueued_buffers = self.read_register(2)

    def enqueue_buffer(self, stream_id: int, vaddr: int, size: int, bytes_per_fpga_transfer: int):
        """
        Enqueues a buffer of size bytes starting at vaddr for the output of the given stream.
        """
        assert stream_id < self.num_streams
        assert vaddr < pow(2, constants.VADDR_BITS)
        assert 0 < size < pow(2, INTERRUPT_TRANSFER_SIZE_BITS)
        assert size % bytes_per_fpga_transfer == 0, (
            f"Buffer size {size} is not a multiple of the transfer size {bytes_per_fpga_transfer}"
        )

        buffer_size_bits = INTERRUPT_TRANSFER_SIZE_BITS - int(math.log2(bytes_per_fpga_transfer))
        size_as_num_transfers = size // bytes_per_fpga_transfer

        self.write_register(stream_id, vaddr << buffer_size_bits | size_as_num_transfers)

    def flush_buffers(self):
        """
        Flushes potentially stale buffers in hardware.
        """
        self.write_register(self.num_streams, 0)


class StreamConfig(Config):
    """
    Configures the type and select of streams.
    """

    ID = 1

    def __init__(self, registers: RegisterAccess, addr_offset: int, num_regs: int):
        super().__init__(registers, addr_offset, num_regs)
        self.num_streams = self.read_register(1)

    @staticmethod
    def register_value(data_type: StreamType, select: int = 0) -> int:
        assert 0 <= select < pow(2, 8)
        return select << 3 | stream_type_to_libstf_type_t(data_type)

    def enqueue_stream_config(self, stream_id: int, data_type: StreamType, select: int = 0):
        assert stream_id < self.num_streams

        self.write_register(stream_id, StreamConfig.register_value(data_type, select))


class GenericConfig(Config):
    """
    Exposes a number of signals as readable and writeable registers.
    """

    ID = pow(2, REGISTER_BITS) - 1 # GENERIC_CONFIG_ID = -1

    def read(self, idx: int) -> int:
        # Register 0 contains the configuration ID
        return self.read_register(idx + 1)

    def write(self, idx: int, value: int):
        self.write_register(idx, value)
