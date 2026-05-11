# Extension to the FPGATestCase and FPGAPerformanceTestCase classes with behavior specific to
# tests with an output writer.
from coyote_test import (
    fpga_performance_test_case,
    fpga_stream,
    simulation_time,
    io_writer,
)
from unit_test.utils.thread_handler import SafeThread
from libstf_utils.configured_test_case import ConfiguredTestCase
from libstf_utils.memory_manager import FPGAOutputMemoryManager
from typing import Union, List, Dict, Optional
import threading


class OutputWriterMixin(ConfiguredTestCase):
    """
    This class provides all the needed extensions for the FPGATestCases.
    It gets mixed in below into the "normal" and the "performance" test case classes.
    Do NOT use this class directly.
    """

    def setUp(self):
        super().setUp()
        self.memory_manager = FPGAOutputMemoryManager(
            self.get_io_writer(),
            self.global_config,
            all_done_callback=self.memory_manager_all_done_callback_spawner,
        )
        # Streams who's output is expected on the card stream
        self.output_card_streams = []
        # expected_output[stream] is a list of expected outputs, one per set_expected_output() call.
        # Each entry corresponds to one acquire_output_handle() call on the software side.
        self.expected_output: Dict[int, List[Union[fpga_stream.Stream, bytearray]]] = {}
        self.card_thread = None

    def memory_manager_all_done_callback_spawner(self):
        if len(self.output_card_streams) > 0:
            # Needs to spawn its own thread to we can perform blocking
            # IO operations. Otherwise, reading the output is blocked!
            self.card_thread = SafeThread(self.memory_manager_all_done_callback)
            self.card_thread.start()
        else:
            # Very important: Mark all io input as done so
            # the simulation can terminate.
            self.get_io_writer().all_input_done()

    def memory_manager_all_done_callback(self, stop_event):
        # For every stream that has output as card memory,
        # Explicitly transfer this memory to the host!
        transfers = 0
        for card_stream in self.output_card_streams:
            for transfer_locations in self.memory_manager.get_transfers(card_stream):
                for vaddr, len in transfer_locations:
                    self.get_io_writer().invoke_transfer(
                        io_writer.CoyoteOperator.LOCAL_SYNC,
                        io_writer.CoyoteStreamType.STREAM_CARD,
                        0,
                        vaddr,
                        len,
                        True,
                    )
                    transfers += 1

        # Wait blocking for sync to finish
        if transfers > 0:
            self.get_io_writer().block_till_completed(
                io_writer.CoyoteOperator.LOCAL_SYNC, transfers, stop_event
            )

        # Very important: Mark all io input as done so
        # the simulation can terminate.
        self.get_io_writer().all_input_done()

    def simulate_fpga_non_blocking(self):
        self.overwrite_simulation_time(simulation_time.SimulationTime.till_finished())
        return super().simulate_fpga_non_blocking()

    def finish_fpga_simulation(self):
        super().finish_fpga_simulation()

        # Wait for the CARD memory thread, if it exists
        if self.card_thread is not None:
            self.card_thread.join_blocking()

    def set_expected_output(
        self,
        stream: int,
        output: Union[fpga_stream.Stream, bytearray],
        stream_type=io_writer.CoyoteStreamType.STREAM_HOST,
    ):
        """
        Registers one expected transfer for the given stream, mirroring one
        acquire_output_handle() call on the software side.

        Calling this multiple times with the same stream registers multiple sequential
        transfers, matched in order against the output produced by the FPGA.
        """
        assert stream_type != io_writer.CoyoteStreamType.STREAM_RDMA, (
            "RDMA streams are not supported atm"
        )

        if stream not in self.expected_output:
            if stream_type == io_writer.CoyoteStreamType.STREAM_CARD:
                self.output_card_streams.append(stream)
            self.expected_output[stream] = []
        else:
            # Assert that the stream type did not change
            if stream_type == io_writer.CoyoteStreamType.STREAM_CARD:
                assert stream in self.output_card_streams, (
                    "Stream type cannot change between outputs!"
                )
            elif stream_type == io_writer.CoyoteStreamType.STREAM_HOST:
                assert stream not in self.output_card_streams, (
                    "Stream type cannot change between outputs!"
                )

        self.expected_output[stream].append(output)
        self.memory_manager.add_transfer_for_stream(stream)

    def _set_expected_memory_content_for_streams(self) -> None:
        """
        Based on the expected output and the actual output in the memory_manager,
        this method sets sets the expected memory content to assert the
        FPGA-initiated transfer output data
        """
        for stream, expected_outputs in self.expected_output.items():
            all_transfer_locations = self.memory_manager.get_transfers(stream)

            assert len(expected_outputs) == len(all_transfer_locations), (
                f"Stream {stream}: expected {len(expected_outputs)} transfer(s) "
                + f"but the FPGA produced {len(all_transfer_locations)} transfer(s)."
            )

            # Determine stream type from the first output
            stream_type: Optional[fpga_stream.StreamType] = None
            if isinstance(expected_outputs[0], fpga_stream.Stream):
                stream_type = expected_outputs[0].stream_type()

            for transfer_index, (expected_out, transfer_locations) in enumerate(
                zip(expected_outputs, all_transfer_locations)
            ):
                expected_bytes = self._convert_data_to_bytearray(
                    expected_out, stream, "output"
                )

                total_length = 0
                for batch, (vaddr, length) in enumerate(transfer_locations):
                    chunk = expected_bytes[total_length : total_length + length]
                    total_length += length
                    self.set_expected_data_at_memory_location(
                        vaddr,
                        chunk,
                        length,
                        f"{stream};Transfer-{transfer_index};Batch-{batch}",
                        stream_type,
                    )

                if total_length != len(expected_bytes):
                    if total_length < len(expected_bytes):
                        raise AssertionError(
                            f"The FPGA sent less output than expected on stream {stream} "
                            + f"transfer {transfer_index}. "
                            + f"A total of {len(expected_bytes)} bytes of output were expected, "
                            + f"but only {total_length} bytes were received from the device."
                        )
                    else:
                        raise AssertionError(
                            f"The FPGA sent more output than expected on stream {stream} "
                            + f"transfer {transfer_index}. "
                            + f"A total of {len(expected_bytes)} bytes of output were expected, "
                            + f"but {total_length} bytes were received from the device."
                        )

    def assert_simulation_output(self):
        # Assert the content is correct
        self._set_expected_memory_content_for_streams()
        super().assert_simulation_output()


class OutputWriterTestCase(OutputWriterMixin):
    pass


class OutputWriterDisabledPerformanceTestCase(fpga_performance_test_case.FPGAPerformanceTestCase):
    """
    This is the default performance test case class that should be used
    for 99% of the performance tests in this repo.
    This test case adheres to all the properties as described in
    the docs: https://github.com/fpgasystems/Coyote/tree/software-cleanup/sim/unit_test
    """

    def simulate_fpga_non_blocking(self) -> threading.Event:
        self.overwrite_simulation_time(simulation_time.SimulationTime.till_finished())
        # Disable the output writer
        if self.verbose_logging:
            self._custom_defines["DISABLE_OUTPUT_WRITER"] = "1"

        return super().simulate_fpga_non_blocking()


class OutputWriterPerformanceTestCase(
    OutputWriterMixin, fpga_performance_test_case.FPGAPerformanceTestCase
):
    """
    This class allows to run performance test with the output writer enabled.
    Note: By default, performance tests should not be run using the output writer.
          The reason is that the output writer will buffer all output in a FIFO
          before initiating transfers to the test bench.
          This buffering behavior means that any potential performance problems
          (e.g. not producing one data beat per cycle), are hidden and
          will instead appear as additional latency.
          This class only exists to test the performance of the output writer
          itself and should not be used to test performance of other
          components.
    """

    # Note: This class inherits from both the mixin and the performance test case.
    # Linearization/call order for super() calls is: 1. Mixin, 2. PerformanceTestCase, 3. FPGATestCase
    pass
