#pragma once

#include <queue>
#include <vector>

#include <coyote/cThread.hpp>

#include <libstf/common.hpp>
#include <libstf/configuration.hpp>
#include <libstf/memory_pool.hpp>
#include <libstf/tlb_manager.hpp>
#include <libstf/output_handle.hpp>

namespace libstf {

enum class BufferAllocationStrategy {
    // Allocates only the minimum, needed amount for every stream.
    // This is equal to FPGAConstants::MEMORY_BYTES_PER_FPGA_TRANSFER
    MINIMIZE_MEMORY_FOOTPRINT = 0,
    // Allocates the maximum allocation size for every stream. This is the default.
    // This strategy creates the least amount of interrupts/stalls on the FPGA and is therefore
    // the most performant.
    // Each allocation is equal to FPGAConstants::MAXIMUM_HOST_MEMORY_ALLOCATION_SIZE_BYTES.
    MAXIMUM_ALLOCATION_SIZE = 1
}; 

class OutputBufferManager {
public:
    /**
     * Creates a new output buffer manager. The manager is responsible for managing buffers for any
     * output produced by the FPGA. This implementation relies on CSR registers and interrupts
     * that tell the OutputBufferManager how much memory was written by the FPGA.
     * @param cthread
     * @param mem_config
     * @param memory_pool
     * @param tlb_manager
     */
    OutputBufferManager(std::shared_ptr<coyote::cThread> cthread, MemConfig &mem_config, 
        std::shared_ptr<MemoryPool> memory_pool, 
        std::shared_ptr<TLBManager> tlb_manager, stream_t num_streams);

    ~OutputBufferManager();

    /**
     * Sets the memory allocation strategy to use for all future allocations. If you want the
     * strategy to take effect for initial allocations, you need to perform this call BEFORE
/    * marking any stream as output stream.
     *
     * The memory allocation can influence the performance of the FPGA-initiated transfers
     * and the memory footprint of the OutputBufferManager.
     *
     * @param strategy The new strategy to use to allocation FPGA output memory.
     */
    void set_memory_allocation_strategy(BufferAllocationStrategy strategy) {allocation_strategy = strategy;};

    /**
     * Function that should be invoked whenever an interrupt from the FPGA is captured
     * via the coyote::cThread.
     * @param value The value of the interrupt
     */
    void handle_fpga_interrupt(int value);

    /**
     * Indicates that a set of streams providedby the provided mask will receive at least one data 
     * beat from your design. This can also be an empty data beat (e.g. keep all 0 and last = 1). It
     * returns a handle that the data can be retrieved from eventually. The method may be called
     * multiple times to essentially enqueue multiple output stream sets.
     *
     * @param active_streams A mask of the streams to wait on for output. Only the first NUM_STREAMS 
     * bits may be set.
     * @return A handle to read the data from.
     */
    std::shared_ptr<OutputHandle> acquire_output_handle(stream_mask_t active_streams);

    /**
     * Flushes all currently enqueued buffers in hardware. This is necessary after the software is
     * done because it leaves behind stale buffers.
     */
    void flush_buffers();

private:
    // We need to pass these because otherwise we will get a circular dependency to the CelerisContext
    std::shared_ptr<coyote::cThread> cthread;
    MemConfig mem_config;
    std::shared_ptr<MemoryPool> memory_pool;
    std::shared_ptr<TLBManager> tlb_manager;

    static constexpr size_t NUM_BUFFERS_TO_ENQUEUE = 2;
    const stream_t NUM_STREAMS;

    // Allocation strategy to use
    BufferAllocationStrategy allocation_strategy;

    // State for each stream
    // There is one mutex to protect and changes in the stream_state.
    // This makes this implementation effectively single-threaded. However,
    // it seems very unlikely that it is required to e.g. read several stream outputs
    // simultaneously. This also means it's sufficient to hold a lock guard in the public functions.
    // No explicit locking in the private functions is needed!
    std::mutex enqueued_buffers_mutex;
    std::vector<std::queue<std::shared_ptr<OutputHandle>>> enqueued_handles;
    std::vector<std::queue<Buffer>> enqueued_buffers;

    /**
     * Releases all memory in the given queue of buffers
     * @param queue
     */
    void free_buffers_in_queue(std::queue<Buffer>& queue);

    /**
     * For the given stream_id, takes the currently used buffer from the
     * FIFO of memory_in_use and places it into the memory that has been transferred.
     * Additionally, the memory is resized to fit the size actually used by the FPGA!
     * @param stream_id
     * @param bytes_written
     * @param last
     */
    void move_current_buffer_to_handle(stream_t stream_id, uint32_t bytes_written, bool last);

    /**
     * @return The next amount of memory in bytes to allocate
     */
    size_t get_next_buffer_capacity();

    /**
    * Allocates a new buffer for the given stream and sends it to the FPGA.
    * @param stream_id
    */
    void enqueue_buffer_for_stream(stream_t stream_id);
    
    /**
    * Allocates new buffers for the given stream until there are at least NUM_BUFFERS_TO_ENQUEUE.
    * @param stream_id
    */
    void ensure_stream_has_buffers(stream_t stream_id);

    /**
     * Write the CSR register for this stream's buffer vaddr
     */
    void write_vaddr_register(stream_t stream_id, size_t vaddr);

    /**
     * Write the CSR register for this stream's buffer size
     */
    void write_size_register(stream_t stream_id, size_t size);

    /**
     * Writes the CSR registers to add a new buffer to the FPGA for the given stream.
     * @param stream_id The stream this buffer is done for
     * @param buffer The buffer to write the registers for
     */
    void write_register_for_buffer(stream_t stream_id, Buffer &buffer);
};

}  // namespace libstf
