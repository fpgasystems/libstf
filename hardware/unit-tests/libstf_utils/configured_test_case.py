# Small extension to the FPGATestCase classes with behavior specific to
# tests that use the libstf configuration utils.
from contextlib import contextmanager
from typing import List, Optional, Union
import threading
from coyote_test import (
    fpga_test_case,
    io_writer,
)
from libstf_utils.fpga_configuration import GlobalConfig


class ConfiguredTestCase(fpga_test_case.FPGATestCase):
    """
    This class provides all the needed extensions for the FPGATestCases. The configuration is
    discovered after the simulation starts because discovery uses blocking configuration register
    reads. Therefore, all configuration writes, inputs, and expected outputs have to be set in
    configure(), which simulate_fpga() calls after the configuration discovery.

    Performance tests should write the configuration registers directly instead, see the README.
    """

    def setUp(self):
        super().setUp()

        self.config = GlobalConfig(self)

        self._input_batch: Optional[List[Union[bytes, bytearray]]] = None
        self._input_batch_lock = threading.Lock()
        self._input_queue_put = None

    def configure(self):
        """
        Override this to write the configuration and set the inputs and expected outputs. Runs
        after the simulation started and the configuration was discovered.
        """
        pass

    def finish_input(self, end_event: threading.Event):
        """
        Marks all input as done once all expected outputs were written. Override this if something
        else is responsible for marking the input as done.
        """
        if self._expected_completed_write_transfers > 0:
            self.get_io_writer().block_till_completed(
                io_writer.CoyoteOperator.LOCAL_WRITE,
                self._expected_completed_write_transfers,
                end_event,
            )

        self.get_io_writer().all_input_done()

    def read_register(self, id: int, stop_event: threading.Event = None) -> Optional[int]:
        if self._input_batch is None:
            return super().read_register(id, stop_event)

        # The read request has to reach the simulation to return. Thus, we flush the batch and pause
        # batching during the read.
        queue = self.get_io_writer().input_queue
        self._flush_input_batch()
        del queue.put
        try:
            return super().read_register(id, stop_event)
        finally:
            queue.put = self._add_to_input_batch

    def _flush_input_batch(self):
        with self._input_batch_lock:
            if self._input_batch:
                self._input_queue_put(b"".join(self._input_batch))
                self._input_batch = []

    def _add_to_input_batch(self, item: Union[bytes, bytearray]):
        with self._input_batch_lock:
            self._input_batch.append(item)

    @contextmanager
    def _batched_input(self):
        """
        The testbench reads the input while the simulation is running and waits a cycle whenever no
        input is available. Therefore, the simulation timing depends on when the host writes the
        input. To keep the timing deterministic, we hand all input written in this context to the
        IO writer as a single element, which the simulation sees at once because a single pipe write
        is atomic for the reader if it fits into the pipe buffer (64 KiB).
        """
        queue = self.get_io_writer().input_queue
        self._input_queue_put = queue.put
        self._input_batch = []
        queue.put = self._add_to_input_batch
        try:
            yield
        finally:
            del queue.put
            self._flush_input_batch()
            self._input_batch = None

    def simulate_fpga(self):
        end_event = self.simulate_fpga_non_blocking()

        self.config.discover(end_event)
        with self._batched_input():
            self.configure()
        self.finish_input(end_event)

        self.finish_fpga_simulation()

