#pragma once

#include <sys/mman.h>

#include <atomic>
#include <cassert>
#include <iostream>
#include <mutex>
#include <unordered_map>
#include <cstring>
#include <sstream>
#include <shared_mutex>
#include <thread>

#include "jemalloc/jemalloc.h"

#include "libstf/error_handling.hpp"

typedef std::shared_mutex ReaderWriterLock;
typedef std::unique_lock<ReaderWriterLock> WriteLock;
typedef std::shared_lock<ReaderWriterLock> ReadLock;

namespace libstf {

/**
 * Base class for memory pools in libstf.
 */
class MemoryPool {
public:
    virtual ~MemoryPool() = default;

    /**
     * Allocates a memory block of at least the specified size.
     * 
     * @param size The minimum number of bytes to allocate.
     * @param alignment The required alignment for the memory block.
     * @param out Pointer to store the address of the allocated memory.
     * @return Status indicating success or failure.
     */
    virtual Status allocate(size_t size, size_t alignment, void **out) = 0;
    virtual Status allocate(size_t size, void **out) = 0;

    /**
     * Resizes an existing allocated memory block.
     * 
     * Since most platform allocators do not support aligned reallocation,
     * this operation may involve copying the data to a new memory block.
     * @param old_size The current size of the allocated memory block.
     * @param new_size The desired new size of the memory block.
     * @param alignment The alignment requirement of the memory block.
     * @param ptr Pointer to the memory block to be resized. Updated on success.
     * @return Status indicating success or failure.
     */
    virtual Status reallocate(size_t old_size, size_t new_size, size_t alignment, void **ptr) = 0;

    /**
     * Frees a previously allocated memory block.
     * 
     * @param ptr Pointer to the start of the allocated memory block.
     * @param size The size of the allocated memory block.
     *        Some allocators may use this for tracking memory usage or
     *        optimizing deallocation.
     * @param alignment The alignment of the memory block.
     */
    virtual void free(void *ptr, size_t size, size_t alignment) = 0;
    virtual void free(void *ptr, size_t size) = 0;

    /**
     * Returns the address and size for the page in which the given allocation was placed.
     * This information can be used, e.g. for TLB mappings on FPGAs.
     * @param ptr The address where the allocation begins, as returned by 'allocate'
     * @return A pair of: Start address and size of the allocated page
     */
    virtual std::pair<void *, size_t> get_page_boundaries(const void *ptr) = 0;

    /**
     * Retrieves the current amount of allocated memory that has not been freed.
     * 
     * @return The number of bytes currently allocated.
     */
    virtual size_t bytes_allocated() const = 0;

    /**
     * Retrieves the total amount of memory allocated since the pool's creation.
     * 
     * @return The cumulative number of bytes allocated.
     */
    virtual size_t total_bytes_allocated() const = 0;

    /**
     * Retrieves the total number of allocation and reallocation requests.
     * 
     * @return The number of times memory has been allocated or reallocated.
     */
    virtual size_t num_allocations() const = 0;

    /**
     * Retrieves the peak memory usage recorded by this memory pool.
     * 
     * @return The highest number of bytes allocated at any point.
     *         Returns -1 if tracking is not implemented.
     */
    virtual size_t max_memory() const = 0;

    /**
     * Retrieves the name of the memory allocation backend in use.
     * 
     * @return A string representing the backend (e.g., "system", "jemalloc").
     */
    virtual std::string backend_name() const = 0;
};

// A static piece of memory for 0-size allocations, to return an aligned non-null pointer. This is 
// required because Arrow memory pools (when we use this in other projects) need to support 0-byte 
// allocations, reallocations, and deallocations but jemalloc does not support them!
extern int64_t zero_size_data[1];
static void *const ZeroSizePointer = reinterpret_cast<void *>(&zero_size_data);

/**
 * This class implements a MemoryPool that uses 1GiB huge pages.
 * This is required for the FPGA support since all the data send/received from the FPGA
 * needs to be mapped on the FPGAs TLB. Additionally, every TLB miss causes an FPGA-side interrupt
 * and is handled in Coyotes kernel code. As small pages lead to many TLB misses, this can cause
 * performance problems due to the large number of interrupts. The goal of this pool is to minimize
 * such misses by using huge pages.
 *
 * The pool is implemented as follows: During initialization, it pre-allocates all available 1GiB
 * pages in the system.  Under the hood it uses jemalloc to handle the actual
 * allocation/free requests. Jemalloc uses smart (and very complex) mechanisms to minimize
 * fragmentation. However, whenever it runs out of memory, it asks this pool via extension_hooks,
 * which provides a chunk of the pre-allocated memory. The pre-allocated 1GiB pages will be
 * unmaped/freed when the MemoryPool is destroyed.
 */
class HugePageMemoryPool : public MemoryPool {
public:
    // The size of the pages to use. These are 1GiB huge pages by default
    static inline const size_t HUGE_PAGE_BITS = 30;
    static inline const size_t PAGE_SIZE      = 1 << HUGE_PAGE_BITS;
    static inline const size_t PAGE_SIZE_KB   = PAGE_SIZE / 1024;
    static inline const size_t HUGE_PAGE_TYPE = (HUGE_PAGE_BITS << MAP_HUGE_SHIFT);

    // Note: This alignment is required by Coyote anyway
    static inline const size_t DEFAULT_ALIGNMENT = 64;

    HugePageMemoryPool();
    ~HugePageMemoryPool();

    Status allocate(size_t raw_size, size_t alignment, void **out) override;
    Status allocate(size_t size, void **out) override { return allocate(size, DEFAULT_ALIGNMENT, out); }

    Status reallocate(size_t old_size, size_t new_size, size_t alignment, void **ptr) override;

    void free(void *ptr, size_t size, size_t alignment) override;
    void free(void *ptr, size_t size) override { free(ptr, size, DEFAULT_ALIGNMENT); }

    std::pair<void *, size_t> get_page_boundaries(const void *ptr) override;

    /**
     * @param ptr The start address of the buffer to check
     * @param size The size of the buffer to check
     * @return Whether the given buffer and size have been allocated by this memory pool
     */
    bool is_in_bounds(void *ptr, size_t size);

    size_t bytes_allocated()       const override { return bytes_allocated_.load(); }
    size_t total_bytes_allocated() const override { return total_bytes_allocated_.load(); }
    size_t num_allocations()       const override { return num_allocs_.load(); }
    size_t max_memory()            const override { return std::numeric_limits<size_t>::max(); }
    std::string backend_name()     const override { return "HugePageMemoryPool"; }

    void *initial_address() const { return initial_address_; }
    size_t total_capacity() const { return total_capacity_; }

private:
    /**
     * @return The number of huge pages with PAGE_SIZE currently available in the system.
     * Ensures this number is > 0
     */
    int get_number_of_available_huge_pages();

    // Call back functions that get called by jemalloc to manage the underlying memory
    static void* huge_page_alloc(extent_hooks_t *hooks,
                               void *new_addr,
                               size_t size,
                               size_t alignment,
                               bool *zero,
                               bool *commit,
                               unsigned arena_ind);

    static bool huge_page_dealloc(
        extent_hooks_t *hooks, void *addr, size_t size, bool committed, unsigned arena_ind);

    static bool huge_page_decommit(
        extent_hooks_t *hooks, void *addr, size_t size, size_t offset, size_t length, unsigned arena_ind);

    static bool huge_page_split_extend(
        extent_hooks_t *hooks, void* addr, size_t size, size_t size_a, size_t size_b, bool committed, unsigned arena_ind);

    static bool huge_page_merge_extend(
        extent_hooks_t *hooks, void *addr_a, size_t size_a, void *addr_b, size_t size_b, bool committed, unsigned arena_ind);

    // Explicit management of thread caches (or tcaches)
    unsigned get_tcache_id_for_calling_thread();
    ReaderWriterLock tcache_lock;
    std::unordered_map<std::thread::id, unsigned> tcache_ids;

    // The index of the area we allocate
    unsigned arena_index;
    // The struct of hooks we use for the allocation
    // Needs to be static to ensure it lives long enough
    static inline extent_hooks_t hugepage_hooks = {
        huge_page_alloc,        // alloc
        huge_page_dealloc,      // dalloc
        nullptr,                // destroy
        nullptr,                // commit
        huge_page_decommit,     // decommit
        nullptr,                // purge_lazy
        nullptr,                // purge_forced
        huge_page_split_extend, // split
        huge_page_merge_extend  // merge
    };

    // The initial address of the memory we allocate
    // -> Needed for the de-allocation
    void *initial_address_;
    // Total capacity of allocated memory
    size_t total_capacity_;
    // Atomics for the statistics
    std::atomic<size_t> total_bytes_allocated_{0};
    std::atomic<size_t> bytes_allocated_{0};
    std::atomic<size_t> num_allocs_{0};
    // How much capacity is remaining in the allocated huge page memory
    static inline size_t remaining_capacity = 0;
    // The next free address that can be returned to jemalloc
    static inline void *next_free_addr = nullptr;
    static inline std::mutex allocations_mutex_;
};

/**
 * Implements a naive memory pool that is only used for simulation purposes in systems where there 
 * are no huge pages.
 */
class SimpleMemoryPool : public MemoryPool {
public:
    static inline const size_t PAGE_SIZE = 4096;

    // Note: This alignment is required by Coyote anyway
    static inline const size_t DEFAULT_ALIGNMENT = 64;

    SimpleMemoryPool() = default;
    ~SimpleMemoryPool() override;

    Status allocate(size_t size, size_t alignment, void **out) override;
    Status allocate(size_t size, void **out) override { return allocate(size, DEFAULT_ALIGNMENT, out); };

    Status reallocate(size_t old_size, size_t new_size, size_t alignment, void **ptr) override;

    void free(void *ptr, size_t size, size_t alignment) override;
    void free(void *ptr, size_t size) override { free(ptr, size, DEFAULT_ALIGNMENT); };

    std::pair<void *, size_t> get_page_boundaries(const void *ptr) override;

    size_t bytes_allocated()       const override { return bytes_allocated_.load(); };
    size_t total_bytes_allocated() const override { return total_bytes_allocated_.load(); };
    size_t num_allocations()       const override { return num_allocs_.load(); };
    size_t max_memory()            const override { return std::numeric_limits<size_t>::max(); };
    std::string backend_name()     const override { return "SimpleMemoryPool"; };

private:
    // A map of all the pages that have been allocated and mapped for this thread
	std::unordered_map<void *, size_t> allocated_buffers;
    // Recursive mutex to protect allocated_buffers (recursive to allow destructor to call free())
    mutable std::recursive_mutex allocated_buffers_mutex;

    // Atomics for the statistics
    std::atomic<size_t> total_bytes_allocated_{0};
    std::atomic<size_t> bytes_allocated_{0};
    std::atomic<size_t> num_allocs_{0};
};

}  // namespace libstf
