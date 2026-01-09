#pragma once

#include <memory>

#include "libstf/memory_pool.hpp"

namespace libstf {

struct Buffer {
  void *ptr;       // The address at which the buffer begins
  size_t size;     // The actual size of the buffer
  size_t capacity; // The total capacity of the buffer
};

// Deleter struct for allocations that is used to clean up the memory that we
// pass as a shared_ptr.
struct BufferDeleter {
  std::shared_ptr<MemoryPool> memory_pool;

  BufferDeleter(std::shared_ptr<MemoryPool> memory_pool)
      : memory_pool(memory_pool) {}

  void operator()(Buffer const *buffer) const {
    // First: free the allocation the struct manages
    memory_pool->free(buffer->ptr, buffer->capacity);
    // Then: free the struct itself!
    delete buffer;
  }
};

std::shared_ptr<Buffer> make_buffer(std::shared_ptr<MemoryPool> memory_pool,
                                    void *ptr, size_t size, size_t capacity);

} // namespace libstf
