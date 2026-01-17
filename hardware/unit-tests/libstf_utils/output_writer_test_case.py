# Small extension to the FPGATestCase and FPGAPerformanceTestCase classes with behavior specific to 
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
            for vaddr, len in self.memory_manager.get_valid_memory_locations(
                card_stream
            ):
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
        Overwrite that uses FPGA-initiated transfers instead of host-initiated transfers.
        """
        assert stream_type != io_writer.CoyoteStreamType.STREAM_RDMA, (
            "RDMA streams are not supported atm"
        )
        # Mark the stream as output stream in the memory manager
        if not self.memory_manager.is_marked_as_output_stream(stream):
            self.memory_manager.mark_stream_as_output_stream(stream)
            # If the output is expected on the card stream, this needs
            # to be handled differently.
            # See the code in the 'all_done' callback function
            if stream_type == io_writer.CoyoteStreamType.STREAM_CARD:
                self.output_card_streams.append(stream)
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

        # Store the expected output for the stream
        if stream not in self.expected_output:
            self.expected_output[stream] = []
        # If the output is not empty, assert its of the same kind
        if len(self.expected_output[stream]) > 0:
            last_output = self.expected_output[stream][-1]
            assert type(last_output) is type(output), (
                "We only support one type of output per stream. "
                + f"Stream {stream} got {type(last_output)} and {type(output)}."
            )
            if isinstance(last_output, fpga_stream.Stream):
                assert (
                    isinstance(output, fpga_stream.Stream)
                    and output.stream_type() == last_output.stream_type()
                ), (
                    f"Got two Stream outputs with different kind for stream {stream}. "
                    + f"Last output was {output.stream_type()}, new output is {last_output.stream_type()}"
                )
        self.expected_output[stream].append(output)

    def _set_expected_memory_content_for_streams(self) -> None:
        """
        Based on the expected output and the actual output in the memory_manager,
        this method sets sets the expected memory content to assert the
        FPGA-initiated transfer output data
        """
        # First: Merge all inputs to one bytearray per stream
        bytearrays: Dict[int, bytearray] = {}
        stream_types: Dict[int, Optional[fpga_stream.StreamType]] = {}
        for stream in self.expected_output.keys():
            bytearrays[stream] = bytearray()
            # Set the stream types
            stream_types[stream] = None
            if isinstance(self.expected_output[stream][0], fpga_stream.Stream):
                stream_types[stream] = self.expected_output[stream][0].stream_type()

            for expected_out in self.expected_output[stream]:
                bytearrays[stream] += self._convert_data_to_bytearray(
                    expected_out, stream, "output"
                )

        # Now, set the expected output from the output data in the memory manager
        for stream, content in bytearrays.items():
            total_length = 0
            for batch, (vaddr, length) in enumerate(
                self.memory_manager.get_valid_memory_locations(stream)
            ):
                expected_output = content[total_length : total_length + length]
                total_length += length
                self.set_expected_data_at_memory_location(
                    vaddr,
                    expected_output,
                    length,
                    f"{stream};Batch-{batch}",
                    stream_types[stream],
                )
            # Check that the expected and the actual output lengths match
            if total_length != len(content):
                if total_length < len(content):
                    raise AssertionError(
                        f"The FPGA sent less output than expected on stream {stream}. "
                        + f"A total of {len(content)} bytes of output were expected, but "
                        + f"only {total_length} bytes were received from the device."
                    )
                elif total_length > len(content):
                    raise AssertionError(
                        f"The FPGA sent more output than expected on stream {stream}. "
                        + f"A total of {len(content)} bytes of output were expected, but "
                        + f"{total_length} bytes were received from the device."
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
