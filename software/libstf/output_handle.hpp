#pragma once

#include <queue>
#include <vector>
#include <mutex>
#include <condition_variable>
#include <memory>
#include <bitset>
#include <stdexcept>

#include <libstf/common.hpp>
#include <libstf/memory_pool.hpp>
#include <libstf/buffer.hpp>
#include <libstf/common.hpp>

namespace libstf {

typedef std::bitset<MAXIMUM_FPGA_NUM_STREAMS> stream_mask_t;

class OutputHandle {
    friend class OutputBufferManager;

protected:
    /**
     * Protected constructor because we only want the OutputBufferManager to create these.
     */
    OutputHandle(std::shared_ptr<MemoryPool> memory_pool, stream_mask_t active_streams, stream_t num_streams) : 
        NUM_STREAMS(num_streams),
        memory_pool(memory_pool),
        active_streams(active_streams),
        finished_streams(0),
        output_buffers(num_streams) {};

    /**
     * Push a buffer that the FPGA is finished with to the specified stream of this OutputHandle.
     * @param stream_id
     * @param buffer
     */
    void push_buffer(stream_t stream_id, Buffer buffer);

    /**
     * Mark a stream of this OutputHandle as done.
     * @param stream_id
     */
    void mark_done(stream_t stream_id);

public:
    ~OutputHandle();

    /**
     * @param stream_id The stream id to check for. Needs to be marked as an output stream.
     * @return Whether the given stream has output data that has not yet been read.
     * Note: A stream needs to be marked as output stream before this function is called.
     *
     * This call is blocking. I.e., if there is no valid output yet for the stream, but memory has
     * been allocated that the FPGA did not yet write to, this call will block until this memory
     * is either written to, producing valid output, or discarded.
     */
    [[nodiscard]] bool stream_has_more_output(stream_t stream_id);

    /**
     * @return Whether any of the streams that have been marked as output streams has output data
     * that has not yet been read. Requires at least one stream to be marked as output.
     *
     * This call is blocking. I.e. if there is no valid output yet for any stream but memory
     * has been allocated to at least one stream that was not yet written to by the FPGA, the call
     * will block until this memory is either written to or discarded.
     */
    [[nodiscard]] bool any_stream_has_more_output();

    /**
     * @param stream_id The stream_id to return output for
     * @return A shared pointer to a memory allocation with valid output data for the given
     * stream_id. The allocation size matches the length of the data returned from the FPGA.
     * This call is thread safe. If no more output is available, a nullptr will
     * be returned instead of a valid shared_ptr.
     *
     * Note that the returned allocation is managed through a shared pointer: When the pointer
     * goes out of scope, the underlying memory will be freed and cannot be used anymore!
     *
     * This call is blocking. I.e., if there is memory that has been allocated but no data was
     * received from the FPGA yet, the call will block until the FPGA finishes a data transfer
     * to this memory. Note that a blocking call can still result in a nullptr if the FPGA did not
     * have any more output to write to the current allocation.
     */
    std::shared_ptr<Buffer> get_next_stream_output(stream_t stream_id);

private:
    const stream_t NUM_STREAMS;
    std::shared_ptr<MemoryPool> memory_pool;

    stream_mask_t active_streams;   // Streams active for this handle
    stream_mask_t finished_streams; // Streams that have received their last buffer

    // Vector of buffers that the design is finished with (we got an interrupt on).
    // There is one mutex to protect changes in the output_buffers vector.
    // This makes this implementation effectively single-threaded per OutputHandle. However,
    // it seems very unlikely that it is required to e.g. read several stream outputs
    // simultaneously. This also means it's sufficient to hold a lock guard in the public functions.
    // No explicit locking in the private functions is needed!
    std::mutex output_buffers_mutex;
    std::condition_variable output_buffers_cv;
    std::vector<std::queue<Buffer>> output_buffers;

    /**
     * @return Whether there is any memory in any stream that is in-flight. Needs to be called
     * with proper locking in place!
     */
    bool any_memory_in_flight() const;

    /**
     * @return Whether there is any stream that has valid output memory to be fetched by the users.
     *  Needs to be called with proper locking in place!
     */
    bool any_stream_output_available() const;

    /**
     * Creates a shared pointer for a Buffer from the first element in the transferred_memory queue 
     * for the given stream. The queue needs to have elements! The shared_ptr manages the underlying 
     * memory, i.e. the ownership is transferred out of this class. When the last reference to the 
     * shared pointer is deleted, the underlying memory of the buffer will be freed.
     * This function needs to be called with proper locking in place!
     */
    std::shared_ptr<Buffer> transferred_mem_front_to_shared_ptr(stream_t stream_id);
};

} // namespace libstf
