from coyote_test import constants, io_writer
from libstf_utils.fpga_configuration import GlobalConfig, MemConfig
from typing import Dict, Tuple, List
from collections.abc import Callable
from libstf_utils.common import (
    INTERRUPT_STREAM_ID_BITS,
    INTERRUPT_TRANSFER_SIZE_BITS,
    INTERRUPT_LAST_BITS,
    MAXIMUM_HOST_MEMORY_ALLOCATION_SIZE_BYTES,
)
import logging
import struct
import threading

MAX_NUMBER_STREAMS = constants.MAX_NUMBER_STREAMS
DEFAULT_BYTES_PER_FPGA_TRANSFER = 65536

class InterruptValue:
    def __init__(self, stream_id: int, transfer_size: int, last: bool):
        self.id = stream_id
        self.size = transfer_size
        self.is_last = last

    def last(self) -> bool:
        return self.is_last

    def transfer_size(self) -> int:
        return self.size

    def stream_id(self) -> int:
        return self.id

    def __str__(self) -> str:
        return f"Transfer for stream {self.stream_id()} over {self.transfer_size()} bytes. Last transfer ? {self.last()}"


class FPGAOutputMemoryManager:
    def __init__(
        self,
        io_writer_inst: io_writer.SimulationIOWriter,
        global_config: GlobalConfig,
        allocation_size = DEFAULT_BYTES_PER_FPGA_TRANSFER,
        transfer_size = DEFAULT_BYTES_PER_FPGA_TRANSFER,
        all_done_callback : Callable[[None], None] = None
    ):
        """
        Creates a new FPGAOutputMemoryManager that manages the memory for FPGA output streams.
        Note: This manager will register a callback at the provided io_writer.
        Therefore, no other callback can be registered when using this manager.

        io_writer = The io writer instance to communicate with the FPGA with
        allocation_size = How much memory to allocate at once for each output stream.
            If this memory becomes full, a new allocation of the same size will be created.
        transfer_size = Size of a single transfer. Only used to validate the allocation_size.
            This should not be overwritten except for tests that require a different transfer size.
        all_done_callback = A function to call when all transfers have been completed.
            Very important: This function is run within the context of a interrupt, which is
            triggered from the io_writer output thread. Therefore, blocking in this function
            will block any progress on reading the IO output.
            Moreover, if defined, this function is responsible for marking all output as done.
        """
        assert isinstance(io_writer_inst, io_writer.SimulationIOWriter)
        assert allocation_size > 0, (
            f"Cannot have zero or negative allocation size. Got {allocation_size}."
        )
        assert allocation_size % transfer_size == 0, (
            f"The provided allocation size of {allocation_size} bytes is NOT "
            + f"a multiple of the FPGA transfer of {transfer_size} bytes."
        )
        assert allocation_size <= MAXIMUM_HOST_MEMORY_ALLOCATION_SIZE_BYTES, (
            f"At most {MAXIMUM_HOST_MEMORY_ALLOCATION_SIZE_BYTES} bytes of allocation "
            + f"are supported at once. {allocation_size} bytes where requested."
        )

        self.io_writer = io_writer_inst
        self.global_config = global_config
        self.allocation_size = allocation_size
        self.transfer_size = transfer_size

        self.all_done_callback = all_done_callback
        self.logger = logging.getLogger("MemoryManager")

        # RLocks allow multi-entry of the same thread
        self.allocation_lock = threading.RLock()
        # All the allocations done for each stream. Key: stream_id.
        # Allocations are a dictionary of vaddr and size
        self.allocations: Dict[int, Dict[int, int]] = {}
        # Per-stream list of transfers. Each transfer is a dict of {vaddr: size}
        # for all memory locations written in that transfer.
        # transfers[stream_id][transfer_index][vaddr] = bytes_written
        self.transfers: Dict[int, List[Dict[int, int]]] = {}
        # How many more last=1 interrupts are expected for each stream before it is fully done.
        self.transfers_remaining: Dict[int, int] = {}

        # Register interrupt handler
        self.io_writer.register_interrupt_handler(self._interrupt_handler)

    #
    # Private methods
    #
    def _write_register_for_allocation(
        self, stream_id: int, vaddr: int, size_bytes: int
    ):
        """
        Writes the required register values to the FPGA for the given data
        """
        self.global_config.get_config(MemConfig).enqueue_buffer(
            stream_id, vaddr, size_bytes, self.transfer_size
        )

    def _extract_bits_from_int32(self, value: int, start_bit: int, num_bits: int):
        """
        Extract num_bits starting from start_bit (0-indexed from right to left)
        """
        assert start_bit + num_bits <= 32, (
            "Cannot extract bits that are out of bound. Requested to "
            + f"extract {num_bits} starting at index {start_bit} from int64."
        )
        # Create mask with num_bits set to 1
        mask = (1 << num_bits) - 1
        return (value >> start_bit) & mask

    def _parse_interrupt_value(self, signed_value: int) -> InterruptValue:
        # The interrupt provides us a signed integer. The data we want to interpret is unsigned.
        value = self._signed_to_unsigned_int32(signed_value)

        # The value encodes:
        # 1. The stream
        stream = self._extract_bits_from_int32(value, 0, INTERRUPT_STREAM_ID_BITS)
        # 2. The size of data that was written to the memory we provided
        transfer_size = self._extract_bits_from_int32(
            value, INTERRUPT_STREAM_ID_BITS, INTERRUPT_TRANSFER_SIZE_BITS
        )
        # 3. Whether all data is done!
        last_bit = self._extract_bits_from_int32(
            value,
            INTERRUPT_STREAM_ID_BITS + INTERRUPT_TRANSFER_SIZE_BITS,
            INTERRUPT_LAST_BITS,
        )

        return InterruptValue(stream, transfer_size, True if last_bit == 1 else False)

    def _add_allocation_for_stream(self, stream_id: int) -> None:
        """
        Extends the memory allocation for the given stream by the configured
        allocation size!
        """
        with self.allocation_lock:
            # Note: We allocate with a 100 byte offset to detect if the
            # FPGA should be writing over the memory bounds.
            new_vaddr = self.io_writer.allocate_next_free_sim_memory(
                self.allocation_size, 100
            )

            # Safe the allocation
            assert stream_id in self.allocations, (
                "Unexpected error: Adding allocation to stream"
                + f" that was never marked as output stream. Id: {stream_id}"
            )
            self.allocations[stream_id][new_vaddr] = self.allocation_size

            # Write new allocation to the FPGA
            self._write_register_for_allocation(
                stream_id, new_vaddr, self.allocation_size
            )
            self.logger.info(
                f"Allocated {self.allocation_size} bytes of memory at vaddr {new_vaddr} for stream {stream_id}"
            )

    def _signed_to_unsigned_int32(self, value: int) -> int:
        return struct.unpack("I", struct.pack("i", value))[0]

    def _get_last_allocation_for_stream(self, stream: int) -> Tuple[int, int]:
        """
        Returns a tuple with the last vaddr and size allocated for the
        given stream
        """
        with self.allocation_lock:
            assert stream in self.allocations, (
                "Got interrupt for stream that was not marked "
                + f"as output. Stream: {stream}"
            )
            # Gets the latest, inserted key in O(1). See: https://stackoverflow.com/a/70321089/5589776
            # This uses the fact that Python keeps the dictionary ordered according to the insertion order!
            last_vaddr = next(reversed(self.allocations[stream]))
            last_size = self.allocations[stream][last_vaddr]
            return (last_vaddr, last_size)

    def _current_transfer_index(self, stream_id: int) -> int:
        """
        Returns the index of the transfer currently being written into for the given stream.
        """
        return len(self.transfers[stream_id]) - 1

    def _handle_stream_last(self, stream_id: int, last: bool) -> None:
        """
        Handling depending on whether the stream send its last data
        """
        if not last:
            # If this was not the last data beat, add a new memory allocation
            self._add_allocation_for_stream(stream_id)
            return

        # One transfer is complete for this stream.
        self.transfers_remaining[stream_id] -= 1
        self.logger.info(
            f"Stream {stream_id} completed a transfer. "
            + f"{self.transfers_remaining[stream_id]} transfer(s) remaining."
        )

        if self.transfers_remaining[stream_id] > 0:
            # More transfers expected: open a new transfer slot and provide the FPGA with
            # a fresh allocation for the next acquire_output_handle cycle.
            self.transfers[stream_id].append({})
            self._add_allocation_for_stream(stream_id)
            return

        # All transfers for this stream are done. Check whether all streams are done.
        if all(r == 0 for r in self.transfers_remaining.values()):
            self.logger.info(
                "All streams are done with transfers. Marking input as done."
            )
            if self.all_done_callback is not None:
                self.logger.info("Invoking all done callback")
                self.all_done_callback()
            else:
                self.io_writer.all_input_done()

    def _interrupt_handler(self, pid: int, interrupt_value: int) -> None:
        assert pid == 0, f"Got unexpected pid != 0 in FPGA interrupt: {pid}"

        # Parse the interrupt value!
        value = self._parse_interrupt_value(interrupt_value)
        self.logger.info(f"FPGA finished {str(value)} ")

        with self.allocation_lock:
            # Get last allocation and perform a sanity check
            (last_vaddr, last_size) = self._get_last_allocation_for_stream(
                value.stream_id()
            )
            assert value.transfer_size() <= last_size, (
                "Got transfer from FPGA that was out of bounds. Allocated "
                + f"{last_size} bytes, but transfer had {value.transfer_size()} bytes."
            )

            # Add the vaddr and size to the active transfer slot for this stream
            current_idx = self._current_transfer_index(value.stream_id())
            self.transfers[value.stream_id()][current_idx][last_vaddr] = (
                value.transfer_size()
            )

        # Handle the next step
        self._handle_stream_last(value.stream_id(), value.last())

    #
    # Public methods
    #
    def get_transfers(self, stream_id: int) -> List[List[Tuple[int, int]]]:
        """
        Returns a list of transfers for the given stream. Each transfer is itself a list
        of (vaddr, size) pairs in the order they were written to by the FPGA.

        get_transfers(stream)[transfer_index] gives all the memory locations
        written during that particular acquire_output_handle cycle.
        """
        assert stream_id < MAX_NUMBER_STREAMS
        with self.allocation_lock:
            if stream_id in self.transfers:
                return [list(t.items()) for t in self.transfers[stream_id]]
            return []

    def add_transfer_for_stream(self, stream_id: int):
        """
        Registers one expected acquire_output_handle() cycle on the given stream.
        Call this once per acquire_output_handle() call on the software side.

        On the first call for a stream, the stream is initialised and the first memory
        allocation is sent to the FPGA. On subsequent calls, the transfer counter is
        incremented; the matching allocation is sent by _handle_stream_last when the
        previous transfer's last=1 interrupt arrives.
        """
        assert stream_id < MAX_NUMBER_STREAMS
        with self.allocation_lock:
            if stream_id not in self.transfers:
                self.allocations[stream_id] = {}
                self.transfers[stream_id] = [{}]
                self.transfers_remaining[stream_id] = 1
                self._add_allocation_for_stream(stream_id)
            else:
                self.transfers_remaining[stream_id] += 1
            self.logger.info(
                f"Added transfer for stream {stream_id}. "
                + f"Total transfers expected: {self.transfers_remaining[stream_id]}"
            )
