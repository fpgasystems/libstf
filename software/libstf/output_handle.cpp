#include "output_handle.hpp"

namespace libstf {

// ----------------------------------------------------------------------------
// Protected methods for OutputBufferManager
// ----------------------------------------------------------------------------
void OutputHandle::push_buffer(stream_t stream_id, Buffer buffer) {
    std::lock_guard guard(output_buffers_mutex);

    output_buffers[stream_id].push(std::move(buffer));

    // Notify all, potentially waiting threads that new output data is available
    output_buffers_cv.notify_all();
}

void OutputHandle::mark_done(stream_t stream_id) {
    std::lock_guard guard(output_buffers_mutex);

    finished_streams.set(stream_id);

    output_buffers_cv.notify_all();
}

// ----------------------------------------------------------------------------
// Public methods
// ----------------------------------------------------------------------------
OutputHandle::~OutputHandle() {
    std::lock_guard guard(output_buffers_mutex);

    // Free any memory that has not been taken by users
    for (auto &queue : output_buffers) {
        while (!queue.empty()) {
            const auto &buffer = queue.front();
            memory_pool->free(buffer.ptr, buffer.capacity, HugePageMemoryPool::DEFAULT_ALIGNMENT);
            queue.pop();
        }
    }
}

bool OutputHandle::stream_has_more_output(stream_t stream_id) {
    if (stream_id >= NUM_STREAMS) {
        throw std::invalid_argument("Stream ID larger than the number of streams");
    }
    if (!active_streams.test(stream_id)) {
        throw std::invalid_argument("Stream is not active for this OutputHandle");
    }

    std::unique_lock guard(output_buffers_mutex);

    // Determine if we already have output to return
    if (!output_buffers[stream_id].empty()) {
        return true;
    }

    // There is no output yet but there might be memory in flight. Let's wait if the in-flight
    // memory turns into a valid output (it might not).
    // Note: the wait releases the lock, waits for a notification on the condition variable,
    // acquires the lock again and then continues execution.
    // It can be the case that there are multiple threads that are waiting for the next output
    // although only one more output is available!
    // To prevent threads from blocking forever in such a case, we always notify all waiting threads!
    // If we were to only notify one waiting thread, the others would wait forever.
    // However, this means we need to check if there is actual data available after every notification.
    // It can happen that this is not the case and that no more output exists!
    // -> We return a false in this case!
    // This implementation prevents any problems should the OutputHandle be called with multiple
    // threads. However, the most performant variant will be single-threaded calls!
    output_buffers_cv.wait(guard, [&] {
        return !output_buffers[stream_id].empty() || finished_streams.test(stream_id);
    });
    return !output_buffers[stream_id].empty();
}

bool OutputHandle::any_stream_has_more_output() {
    std::unique_lock guard(output_buffers_mutex);

    // Check if there is available data in any of the streams
    if (any_stream_output_available()) {
        return true;
    }

    // Like in the 'stream_has_more_output' function above, we wait for any new output memory while
    // there is still any memory in flight. Read the above comment for an explanation why this works!
    output_buffers_cv.wait(guard, [this] {
        return any_stream_output_available() || !any_memory_in_flight();
    });

    return any_stream_output_available();
}

std::shared_ptr<Buffer> OutputHandle::get_next_stream_output(stream_t stream_id) {
    if (stream_id >= NUM_STREAMS) {
        throw std::invalid_argument("Stream ID larger than the number of streams");
    }
    if (!active_streams.test(stream_id)) {
        throw std::invalid_argument("Stream is not active for this OutputHandle");
    }

    std::unique_lock guard(output_buffers_mutex);

    // Check if there is already output we can use without having to wait.
    if (!output_buffers[stream_id].empty()) {
        return transferred_mem_front_to_shared_ptr(stream_id);
    }

    // There is no output yet. While memory is still in flight, wait for more output to become 
    // available. Return a nullptr if output never becomes available. This is the same mechanism as 
    // in the two 'stream_has_more_output' and 'any_stream_has_more_output' functions above.
    output_buffers_cv.wait(guard, [&] {
        return !output_buffers[stream_id].empty() || finished_streams.test(stream_id);
    });

    if (!output_buffers[stream_id].empty()) {
        return transferred_mem_front_to_shared_ptr(stream_id);
    } else {
        return nullptr;
    }
}

// ----------------------------------------------------------------------------
// Private methods
// ----------------------------------------------------------------------------
bool OutputHandle::any_stream_output_available() const {
    for (stream_t i = 0; i < output_buffers.size(); i++) {
        if (!output_buffers[i].empty()) {
            return true;
        }
    }
    return false;
}


bool OutputHandle::any_memory_in_flight() const {
    for (stream_t i = 0; i < output_buffers.size(); i++) {
        if (active_streams.test(i) && !finished_streams.test(i)) {
            return true;
        }
    }
    return false;
}

std::shared_ptr<Buffer> OutputHandle::transferred_mem_front_to_shared_ptr(stream_t stream_id) {
    auto buffer = output_buffers[stream_id].front();

    // Create a shared pointer with custom deleter that frees the underlying memory!
    // Note: We create a copy of the struct here since the struct instance of the queue
    // is owned by the queue.
    auto result = make_buffer(memory_pool, buffer.ptr, buffer.size, buffer.capacity);

    // Pop the queue element and return the pointer!
    output_buffers[stream_id].pop();
    return result;
}

} // namespace libstf
