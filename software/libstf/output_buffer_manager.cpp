#include <libstf/memory_pool.hpp>
#include <libstf/output_buffer_manager.hpp>
#include <libstf/profiling.hpp>

#include <stdexcept>
#include <string>

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

std::ostream &operator<<(std::ostream &out, const InterruptValue &expr) {
    out << "InterruptValue{last = " << expr.last;
    out << ", bytes_written = " << expr.bytes_written;
    out << ", stream_id = " << std::to_string(expr.stream_id) << "}";
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
    result.bytes_written = extract_bits_from_uint32(value, FPGA_INTERRUPT_STREAM_ID_BITS,
                                                    FPGA_INTERRUPT_TRANSFER_SIZE_BITS);
    // 3. Whether this was the last transfer for this stream
    uint32_t last = extract_bits_from_uint32(
        value, FPGA_INTERRUPT_STREAM_ID_BITS + FPGA_INTERRUPT_TRANSFER_SIZE_BITS,
        FPGA_INTERRUPT_LAST_BITS);
    result.last = last == 1;

    return result;
}

const std::string prefix = "libstf::OutputBufferManager::";

// ----------------------------------------------------------------------------
// Public methods
// ----------------------------------------------------------------------------
OutputBufferManager::OutputBufferManager(std::shared_ptr<coyote::cThread> cthread,
                                         std::shared_ptr<MemConfig>       mem_config,
                                         std::shared_ptr<MemoryPool>      memory_pool,
                                         std::shared_ptr<TLBManager>      tlb_manager,
                                         stream_mask_t                    managed_streams,
                                         size_t num_buffers_to_enqueue, size_t buffer_capacity)
    : cthread(cthread), mem_config(mem_config), memory_pool(memory_pool), tlb_manager(tlb_manager),
      NUM_STREAMS(mem_config->num_streams()), MANAGED_STREAMS(managed_streams),
      NUM_BUFFERS_TO_ENQUEUE(num_buffers_to_enqueue), BUFFER_CAPACITY(buffer_capacity),
      enqueued_buffers(NUM_STREAMS), enqueued_handles(NUM_STREAMS) {
    if (NUM_BUFFERS_TO_ENQUEUE == 0)
        throw std::runtime_error("Number of enqueued buffers has to be larger than 0");
    if (NUM_BUFFERS_TO_ENQUEUE > mem_config->maximum_num_enqueued_buffers())
        throw std::runtime_error(
            "Number of enqueued buffers is higher than the maximum supported by the hardware");
    if (BUFFER_CAPACITY < BYTES_PER_FPGA_TRANSFER)
        throw std::runtime_error("Buffer capacity has to be >= " +
                                 std::to_string(BYTES_PER_FPGA_TRANSFER));
    if (BUFFER_CAPACITY >= MAXIMUM_FPGA_BUFFER_SIZE)
        throw std::runtime_error("Buffer capacity has to be < " +
                                 std::to_string(MAXIMUM_FPGA_BUFFER_SIZE));
    if (BUFFER_CAPACITY % BYTES_PER_FPGA_TRANSFER)
        throw std::runtime_error("Buffer capacity has to be a multiple of " +
                                 std::to_string(BYTES_PER_FPGA_TRANSFER));
}

OutputBufferManager::~OutputBufferManager() {
    std::lock_guard guard(enqueued_buffers_mutex);

    // Free any memory that has not been used by the FPGA
    for (auto &queue : enqueued_buffers) {
        free_buffers_in_queue(queue);
    }
}

void OutputBufferManager::handle_fpga_interrupt(int coyote_value) {
    Profiler::open_regions({prefix + "handle_fpga_interrupt"});
    // 1. Parse the value
    auto parsed = parse_interrupt_value(coyote_value);

    // Check that this stream exists
    assert(parsed.stream_id < NUM_STREAMS);

    std::lock_guard guard(enqueued_buffers_mutex);

    // 2. Move buffer from enqueued to it's corresponding handle
    move_current_buffer_to_handle(parsed.stream_id, parsed.bytes_written, parsed.last);

    // 3. Enqueue new buffer — only for managed streams. Unmanaged streams have a single buffer of
    //    the exact size enqueued at acquire time and do not get speculatively topped up.
    if (MANAGED_STREAMS.test(parsed.stream_id)) {
        enqueue_buffer_for_stream(parsed.stream_id);
    }
    Profiler::close_regions({prefix + "handle_fpga_interrupt"});
}

std::shared_ptr<OutputHandle>
OutputBufferManager::acquire_output_handle(stream_mask_t active_mask) {
    assert(active_mask.any() && (active_mask >> NUM_STREAMS).none());
    // All requested streams must be managed by this OBM. Unmanaged streams must use the
    // size-based overload below.
    assert((active_mask & ~MANAGED_STREAMS).none());

    Profiler::open_regions({prefix + "acquire_output_handle"});
    std::shared_ptr<OutputHandle> handle(new OutputHandle(memory_pool, active_mask, NUM_STREAMS));

    std::lock_guard guard(enqueued_buffers_mutex);

    // Only enqueue buffers if we are actually going to use the stream
    for (int i = 0; i < NUM_STREAMS; i++) {
        if (active_mask.test(i)) {
            ensure_stream_has_buffers(i);

            enqueued_handles[i].emplace(handle);
        }
    }

    Profiler::close_regions({prefix + "acquire_output_handle"});
    return handle;
}

std::shared_ptr<OutputHandle> OutputBufferManager::acquire_output_handle(stream_t stream,
                                                                         size_t   size) {
    assert(stream < NUM_STREAMS);
    // This entry point is only for unmanaged streams — managed streams must go through the
    // mask-based overload above.
    assert(!MANAGED_STREAMS.test(stream));
    assert(size > 0);

    Profiler::open_regions({prefix + "acquire_output_handle"});

    stream_mask_t active_mask;
    active_mask.set(stream);
    std::shared_ptr<OutputHandle> handle(new OutputHandle(memory_pool, active_mask, NUM_STREAMS));

    std::lock_guard guard(enqueued_buffers_mutex);

    // The FPGA's per-buffer capacity is bounded by MAXIMUM_OUTPUT_WRITER_BUFFER_SIZE. If the
    // caller-provided size exceeds that, we split it across multiple buffers — each enqueued
    // separately and surfaced to the handle via the regular interrupt path.
    size_t remaining = size;
    while (remaining > 0) {
        size_t chunk = std::min<size_t>(remaining, MAXIMUM_OUTPUT_WRITER_BUFFER_SIZE);
        // Round chunk up to a multiple of BYTES_PER_FPGA_TRANSFER as required by the HW.
        size_t capacity =
            ((chunk + BYTES_PER_FPGA_TRANSFER - 1) / BYTES_PER_FPGA_TRANSFER) *
            BYTES_PER_FPGA_TRANSFER;

        Buffer buffer  = {};
        buffer.capacity = capacity;
        auto res        = memory_pool->allocate(buffer.capacity, &buffer.ptr);
        if (!res.ok()) {
            throw std::runtime_error(
                "OutputBufferManager::acquire_output_handle could not allocate a " +
                std::to_string(buffer.capacity) + " byte output buffer: " + res.message());
        }
        tlb_manager->ensure_tlb_mapping(reinterpret_cast<std::byte *>(buffer.ptr), buffer.capacity);

        enqueued_buffers[stream].push(buffer);
        enqueued_handles[stream].emplace(handle);

        mem_config->enqueue_buffer(stream, buffer);

        remaining -= chunk;
    }

    Profiler::close_regions({prefix + "acquire_output_handle"});
    return handle;
}

void OutputBufferManager::flush_buffers() { mem_config->flush_buffers(); }

// ----------------------------------------------------------------------------
// Private methods
// ----------------------------------------------------------------------------
void OutputBufferManager::free_buffers_in_queue(std::queue<Buffer> &queue) {
    while (!queue.empty()) {
        auto buffer = queue.front();
        memory_pool->free(buffer.ptr, buffer.capacity, HugePageMemoryPool::DEFAULT_ALIGNMENT);
        queue.pop();
    }
}

void OutputBufferManager::move_current_buffer_to_handle(stream_t stream_id, uint32_t bytes_written,
                                                        bool last) {
    assert(!enqueued_handles[stream_id].empty());

    Profiler::open_regions({prefix + "move_current_buffer_to_handle"});
    auto &active_handle = enqueued_handles[stream_id].front();
    auto &active_buffer = enqueued_buffers[stream_id].front();

    // Check that the FPGA did not write out of bounds
    assert(bytes_written <= active_buffer.capacity);

    // Only move the buffer if there was actual output. No output can happen if all output was
    // already sent or there simply was no output. In these cases, an interrupt is still raised for
    // each output stream. Depending on the hardware configuration, the buffer is used up anyway.
    if (bytes_written > 0) {
        // Resize the allocation to fit the actual size written by the FPGA, if not all memory was
        // used.
        if (bytes_written < active_buffer.capacity) {
            auto res =
                memory_pool->reallocate(active_buffer.capacity, bytes_written,
                                        HugePageMemoryPool::DEFAULT_ALIGNMENT, &active_buffer.ptr);
            if (!res.ok()) {
                throw std::runtime_error(
                    "OutputBufferManager::move_current_buffer_to_handle could not shrink output buffer to " +
                    std::to_string(bytes_written) + " bytes: " + res.message());
            }
        }
        active_buffer.size = bytes_written;

        // Transfer to handle
        active_handle->push_buffer(stream_id, active_buffer);
        enqueued_buffers[stream_id].pop();
    } else if (mem_config->empty_stream_consumes_buffer()) {
        // The hardware moved on to the next buffer without writing to this one
        memory_pool->free(active_buffer.ptr, active_buffer.capacity,
                          HugePageMemoryPool::DEFAULT_ALIGNMENT);
        enqueued_buffers[stream_id].pop();
    }

    // If the last signal was received, tell the handle that this stream is done and pop this handle
    // from this streams queue.
    if (last) {
        active_handle->mark_done(stream_id);
        enqueued_handles[stream_id].pop();
    }

    Profiler::close_regions({prefix + "move_current_buffer_to_handle"});
}

void OutputBufferManager::enqueue_buffer_for_stream(stream_t stream_id) {
    Profiler::open_regions({prefix + "enqueue_buffer_for_stream"});

    // 1. Allocate new memory
    Buffer buffer   = {};
    buffer.capacity = BUFFER_CAPACITY;

    auto res = memory_pool->allocate(buffer.capacity, &buffer.ptr);
    if (!res.ok()) {
        throw std::runtime_error(
            "OutputBufferManager::enqueue_buffer_for_stream could not allocate a " +
            std::to_string(buffer.capacity) + " byte output buffer: " + res.message());
    }

    tlb_manager->ensure_tlb_mapping(reinterpret_cast<std::byte *>(buffer.ptr), buffer.capacity);

    // 2. Store buffer
    enqueued_buffers[stream_id].push(buffer);

    // 3. Write the buffer to the FPGA
    mem_config->enqueue_buffer(stream_id, buffer);

    Profiler::close_regions({prefix + "enqueue_buffer_for_stream"});
}

void OutputBufferManager::ensure_stream_has_buffers(stream_t stream_id) {
    while (enqueued_buffers[stream_id].size() < NUM_BUFFERS_TO_ENQUEUE) {
        enqueue_buffer_for_stream(stream_id);
    }
}

} // namespace libstf
