#include <libstf/output_buffer_manager.hpp>
#include <libstf/memory_pool.hpp>

#include <any>

namespace libstf {

// ----------------------------------------------------------------------------
// Interrupt value
// ----------------------------------------------------------------------------

struct InterruptValue {
    // Indicating whether this was all data to be transferred for this stream
    // -> Whether we are done with this stream or additional memory is needed.
    bool last;
    // Number of bytes written by the FPGA
    uint32_t bytes_written;
    // The id of the stream the bytes were written to
    stream_t stream_id;
};

std::ostream& operator<<(std::ostream& out, const InterruptValue& expr) {
    out << "Got interrupt with values: .last = " << expr.last;
    out << ", bytes_written = " << expr.bytes_written;
    out << ", stream_id = " << std::to_string(expr.stream_id);
    return out;
}

/**
 * @return A new integer from value where num_bits starting from start_bit
 *         are extracted (0-indexed from right to left)
 */
uint32_t extract_bits_from_uint32(uint32_t value, uint32_t start_bit, uint32_t num_bits) {
    assert(start_bit + num_bits <= 32);
    // Create mask with num_bits set to 1
    uint32_t mask = (1 << num_bits) - 1;
    return (value >> start_bit) & mask;
}

InterruptValue parse_interrupt_value(int value) {
    // The interrupt encodes:
    InterruptValue result{};
    // 1. Stream id
    result.stream_id = extract_bits_from_uint32(value, 0, FPGA_INTERRUPT_STREAM_ID_BITS);
    // 2. The size of data that was written to the memory we provided
    result.bytes_written = extract_bits_from_uint32(value,
                                                    FPGA_INTERRUPT_STREAM_ID_BITS,
                                                    FPGA_INTERRUPT_TRANSFER_SIZE_BITS);
    // 3. Whether this was the last transfer for this stream
    uint32_t last = extract_bits_from_uint32(
        value,
        FPGA_INTERRUPT_STREAM_ID_BITS + FPGA_INTERRUPT_TRANSFER_SIZE_BITS,
        FPGA_INTERRUPT_LAST_BITS);
    result.last = last == 1;

    return result;
}

// ----------------------------------------------------------------------------
// Public methods
// ----------------------------------------------------------------------------
OutputBufferManager::OutputBufferManager(std::shared_ptr<coyote::cThread> cthread, 
    MemConfig &mem_config, std::shared_ptr<MemoryPool> memory_pool, 
    std::shared_ptr<TLBManager> tlb_manager, stream_t num_streams)
        : cthread(cthread)
        , mem_config(mem_config)
        , memory_pool(memory_pool)
        , tlb_manager(tlb_manager)
        , allocation_strategy(BufferAllocationStrategy::MAXIMUM_ALLOCATION_SIZE)
        , NUM_STREAMS(num_streams)
        , enqueued_buffers(NUM_STREAMS)
        , enqueued_handles(NUM_STREAMS) {}

OutputBufferManager::~OutputBufferManager() {
    std::lock_guard guard(enqueued_buffers_mutex);

    // Free any memory that has not been used by the FPGA
    for (auto &queue : enqueued_buffers) {
        free_buffers_in_queue(queue);
    }
}

void OutputBufferManager::handle_fpga_interrupt(int coyote_value) {
    // 1. Parse the value
    auto parsed = parse_interrupt_value(coyote_value);

    // Check that this stream exists
    assert(parsed.stream_id < NUM_STREAMS);

    std::lock_guard guard(enqueued_buffers_mutex);

    // 2. Move buffer from enqueued to it's corresponding handle
    move_current_buffer_to_handle(parsed.stream_id, parsed.bytes_written, parsed.last);

    // 3. Enqueue new buffer
    enqueue_buffer_for_stream(parsed.stream_id);
}

std::shared_ptr<OutputHandle> OutputBufferManager::acquire_output_handle(stream_mask_t active_mask) {
    assert(active_mask.any() && (active_mask >> NUM_STREAMS).none());

    std::shared_ptr<OutputHandle> handle(new OutputHandle(memory_pool, active_mask, NUM_STREAMS));

    std::lock_guard guard(enqueued_buffers_mutex);

    // Only enqueue buffers if we are actually going to use the stream
    for (int i = 0; i < NUM_STREAMS; i++) {
        if (active_mask.test(i)) {
            ensure_stream_has_buffers(i);

            enqueued_handles[i].emplace(handle);
        }
    }

    return handle;
}

void OutputBufferManager::flush_buffers() {
    mem_config.flush_buffers();
}

// ----------------------------------------------------------------------------
// Private methods
// ----------------------------------------------------------------------------
void OutputBufferManager::free_buffers_in_queue(std::queue<Buffer>& queue) {
    while (!queue.empty()) {
        auto buffer = queue.front();
        memory_pool->free(buffer.ptr, buffer.capacity, HugePageMemoryPool::DEFAULT_ALIGNMENT);
        queue.pop();
    }
}

void OutputBufferManager::move_current_buffer_to_handle(stream_t stream_id, uint32_t bytes_written, bool last) {
    assert(!enqueued_handles[stream_id].empty());
    auto &active_handle = enqueued_handles[stream_id].front();
    auto &active_buffer = enqueued_buffers[stream_id].front();

    // Check that the FPGA did not write out of bounds
    assert(bytes_written <= active_buffer.capacity);

    // Only move the buffer if there was actual output. No output can happen if all output was 
    // already sent or there simply was no output. In these cases, an interrupt is still raised for
    // each output stream.
    if (bytes_written > 0) {
        // Resize the allocation to fit the actual size written by the FPGA, if not all memory was 
        // used.
        if (bytes_written < active_buffer.capacity) {
            auto res = memory_pool->reallocate(active_buffer.capacity,
                                               bytes_written,
                                               HugePageMemoryPool::DEFAULT_ALIGNMENT,
                                               &active_buffer.ptr);
            assert(res.ok());
        }
        active_buffer.size = bytes_written;

        // Transfer to handle
        active_handle->push_buffer(stream_id, active_buffer);
        enqueued_buffers[stream_id].pop();
    }

    // If the last signal was received, tell the handle that this stream is done and pop this handle
    // from this streams queue.
    if (last) {
        active_handle->mark_done(stream_id);
        enqueued_handles[stream_id].pop();
    }
}

size_t OutputBufferManager::get_next_buffer_capacity() {
    switch (allocation_strategy) {
        case BufferAllocationStrategy::MINIMIZE_MEMORY_FOOTPRINT: {
            return BYTES_PER_FPGA_TRANSFER;
        }
        case BufferAllocationStrategy::MAXIMUM_ALLOCATION_SIZE: {
            size_t max_buffer_size = MAXIMUM_FPGA_BUFFER_SIZE;
            // We need to make sure the allocation is a multiple of MEMORY_BYTES_PER_FPGA_TRANSFER
            size_t overlap = max_buffer_size % BYTES_PER_FPGA_TRANSFER;
            return max_buffer_size - overlap;
        }
        default: {
            throw std::runtime_error("OutputBufferManager got unknown allocation strategy");
        }
    }
}

void OutputBufferManager::enqueue_buffer_for_stream(stream_t stream_id) {
    // 1. Allocate new memory
    Buffer buffer = {};
    buffer.capacity       = get_next_buffer_capacity();
    auto alignment        = HugePageMemoryPool::DEFAULT_ALIGNMENT;

    auto res = memory_pool->allocate(buffer.capacity, alignment, &buffer.ptr);
    assert(res.ok());

    tlb_manager->ensure_tlb_mapping(reinterpret_cast<std::byte*>(buffer.ptr), buffer.capacity);

    // 2. Store buffer
    enqueued_buffers[stream_id].push(buffer);

    // 3. Write the buffer to the FPGA
    mem_config.enqueue_buffer(stream_id, buffer);
}

void OutputBufferManager::ensure_stream_has_buffers(stream_t stream_id) {
    while (enqueued_buffers[stream_id].size() < NUM_BUFFERS_TO_ENQUEUE) {
        enqueue_buffer_for_stream(stream_id);
    }
}

}  // namespace libstf
