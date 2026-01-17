#include "libstf/memory_pool.hpp"

#include <fstream>
#include <memory>

using namespace std::chrono_literals;

namespace libstf {

// ----------------------------------------------------------------------------
// Helper functions for Jemalloc
// ----------------------------------------------------------------------------

std::string mallctl_error_to_string(int error) {
    switch (error) {
        case EINVAL:
            return "The alignment parameter is not a power of 2 at least as large as sizeof(void "
                   "*).";
        case ENOENT:
            return "Name or mib specifies an unknown/invalid value.";
        case EPERM:
            return "Attempt to read or write void value, or attempt to write read-only value.";
        case EAGAIN:
            return "A memory allocation failure occurred.";
        case EFAULT:
            return "EFAULT occurred";
        default:
            return "Unknown error.";
    }
}

void check_mallctl_success(int error, std::string msg) {
    if (error != 0) {
        throw std::runtime_error(msg + " Got error: " + mallctl_error_to_string(error));
    }
}

/**
 * Executes the given control name without parameters
 * @param control_name
 */
void je_mallctl_do(std::string control_name) {
    check_mallctl_success(je_mallctl(control_name.c_str(), nullptr, nullptr, nullptr, 0),
                          "Failed to execute mallctl control " + control_name + ".");
}

/**
 * Writes the given value to the jemalloc control with the given name
 * @tparam A Type of the value to write
 * @param control_name The name of the control to write to
 * @param value A pointer to the value to write!
 */
template<typename A>
void je_mallctl_write(std::string control_name, A *value) {
    check_mallctl_success(je_mallctl(control_name.c_str(), nullptr, nullptr, value, sizeof(A)),
                          "Failed to write to mallctl control " + control_name + ".");
}

/**
 * @tparam A The type of value to read
 * @param control_name The name of the control to read from
 * @return A value of type A as returned by the given jemalloc control
 */
template<typename A>
A je_mallctl_read(std::string control_name) {
    A value;
    auto size = sizeof(A);
    check_mallctl_success(je_mallctl(control_name.c_str(), &value, &size, nullptr, 0),
                          "Failed to read from mallctl control " + control_name + ".");
    return std::move(value);
}

/**
 * @tparam A Type of the value to be read
 * @tparam B Type of the value to write
 * @param control_name The control to read/write to
 * @param write_value The value to write
 * @return Reads & Writes from the given jemalloc control name
 */
template<typename A, typename B>
A je_mallctl_read_write(std::string control_name, B *write_value) {
    A read_value;
    auto size = sizeof(A);
    check_mallctl_success(
        je_mallctl(control_name.c_str(), &read_value, &size, write_value, sizeof(B)),
        "Failed to read/write from mallctl control " + control_name + ".");
    return std::move(read_value);
}

// ----------------------------------------------------------------------------
// HugePageMemoryPool implementation
// ----------------------------------------------------------------------------

// Assign a value to the zero_size_data while making sure its aligned according
// to the default alignment.
alignas(HugePageMemoryPool::DEFAULT_ALIGNMENT) int64_t zero_size_data[1] = {0xFFFFULL};

HugePageMemoryPool::HugePageMemoryPool() {
    // Set some default options for jemalloc
    // Immediately reuse pages
    je_mallctl_write<ssize_t>("arenas.dirty_decay_ms", 0);

    // Pre-allocate all 1 Gib huge pages available in the system
    auto num_huge_pages = get_number_of_available_huge_pages();
    next_free_addr      = mmap(nullptr,
                          num_huge_pages * PAGE_SIZE,
                          PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB | HUGE_PAGE_TYPE,
                          -1,
                          0);
    if (next_free_addr == MAP_FAILED) {
        throw std::runtime_error(
            "Could not allocated the expected number of 1GiB huge pages for HugePageMemoryPool.");
    }
    initial_address_   = next_free_addr;
    total_capacity_    = num_huge_pages * PAGE_SIZE;
    remaining_capacity = num_huge_pages * PAGE_SIZE;

    // Create a new jemalloc arena with customs hook
    // -> The hook will request chunks of the 1GiB pages we pre-allocated
    auto hooks  = &hugepage_hooks;
    arena_index = je_mallctl_read_write<unsigned, extent_hooks_t*>("arenas.create", &hooks);
}

HugePageMemoryPool::~HugePageMemoryPool() {
    // Destroy all the tcaches we crated
    // This is REQUIRED for destroying the arena and otherwise will lead to a SEGFAULT
    for (auto tcache : tcache_ids) {
        je_mallctl_write("tcache.destroy", &tcache.second);
    }

    // It can take some time for the tcaches to be cleaned up.
    // Unfortunately, the operation is not blocking.
    // And there is no way to ask if the destruction has finished.
    // This is really stupid. To prevent seg faults during termination,
    // we sleep a fixed time here in the hope that after this, the tcache are destroyed.
    std::this_thread::sleep_for(100ms);

    // Destroy the arena we created
    std::ostringstream arena;
    arena << "arena." << arena_index << ".destroy";
    je_mallctl_do(arena.str());

    // Unmap all the pre-allocated memory
    if (munmap(initial_address_, total_capacity_) == -1) {
        std::cerr << "HugePageMemoryPool: Could not munmap the obtained huge page mappings."
                  << std::endl;
    }
}

int HugePageMemoryPool::get_number_of_available_huge_pages() {
    std::ostringstream path;
    path << "/sys/kernel/mm/hugepages/hugepages-" << PAGE_SIZE_KB << "kB/free_hugepages";
    std::ifstream file(path.str());

    if (!file.is_open()) {
        throw std::runtime_error(
            "It seems the target system does not have 1GiB huge pages enabled, which are required "
            "for FPGA support. Please enable 1GiB huge pages in your system.");
    }

    // Read out the number of free pages
    int free_pages = 0;
    file >> free_pages;
    file.close();
    if (free_pages == 0) {
        throw std::runtime_error(
            "Your system has 0 free 1GiB huge pages. The FPGA support requires 1GiB huge pages. "
            "Please enable additional 1GiB huge pages as described in the Maximus readme.");
    }
    return free_pages;
}

unsigned HugePageMemoryPool::get_tcache_id_for_calling_thread() {
    // Jemalloc automatically allocates a so-called tcache for the calling
    // thread of mallocx, rallocx, or dallocx calls.
    // The Problem is that when we want to destroy the arena, jemalloc requires us to first,
    // destroy all the (automatically created) tcaches.
    // Since they are automatically managed, and we don't know how many threads called our memory
    // pool, we have NO WAY of destroying them all...
    // -> We need to manually manage them. That way, we know all created tcaches
    // and can destroy them
    ReadLock r_lock(tcache_lock);
    auto thread_id = std::this_thread::get_id();
    auto exists    = tcache_ids.find(thread_id);
    if (exists != tcache_ids.end()) {
        r_lock.unlock();
        return exists->second;
    }

    // If we get here, the calling thread does not yet have a tcache. Create one!
    r_lock.unlock();
    WriteLock w_lock(tcache_lock);
    unsigned tcache_id = je_mallctl_read<unsigned>("tcache.create");
    tcache_ids.insert(std::make_pair(thread_id, tcache_id));
    w_lock.unlock();
    return tcache_id;
}

bool HugePageMemoryPool::is_in_bounds(void *ptr, size_t size) {
    auto address     = static_cast<std::byte *>(ptr);
    auto initial     = static_cast<std::byte *>(initial_address_);
    auto max_address = initial + total_capacity_;
    return address >= initial && address + size - 1 <= max_address;
}

std::pair<void *, size_t> HugePageMemoryPool::get_page_boundaries(const void *ptr) {
    auto byte_ptr    = static_cast<const std::byte *>(ptr);
    auto initial     = static_cast<std::byte *>(initial_address_);
    auto max_address = initial + total_capacity_;
    if (byte_ptr < initial || byte_ptr > max_address) {
        std::ostringstream err;
        err << "The Provided address " << static_cast<const void*>(ptr)
            << " is not within the bounds of the HugePageMemoryPool";
        throw std::runtime_error(err.str());
    }

    auto n_th_page = (byte_ptr - initial) / PAGE_SIZE;
    return std::make_pair(static_cast<void *>(initial + n_th_page * PAGE_SIZE), PAGE_SIZE);
}

Status HugePageMemoryPool::allocate(size_t size, size_t alignment, void **out) {
    if (size == 0) {
        *out = ZeroSizePointer;
    } else {
        // Ensure the alignment is a power of two. See: https://stackoverflow.com/a/108360/5589776
        assert((alignment & (alignment - 1)) == 0);
        auto tc = get_tcache_id_for_calling_thread();
        *out    = je_mallocx(
            size, MALLOCX_ALIGN(alignment) | MALLOCX_ARENA(arena_index) | MALLOCX_TCACHE(tc));
        if (*out == nullptr) {
            return Status(StatusCode::OutOfMemory,
                                 "HugePageMemoryPool is unable to allocate memory!");
        }
        total_bytes_allocated_ += size;
        bytes_allocated_ += size;
    }
    num_allocs_ += 1;

    return Status::OK();
}

Status HugePageMemoryPool::reallocate(size_t old_size, size_t new_size, size_t alignment, void **ptr) {
    // We want to allocate from an existing zero allocation
    if (*ptr == ZeroSizePointer) {
        assert(old_size == 0);
        return allocate(new_size, alignment, ptr);
    }
    // We want to decrease the new size to 0
    if (new_size == 0) {
        free(*ptr, old_size, alignment);
        *ptr = ZeroSizePointer;
        return Status::OK();
    }

    // Ensure the alignment is a power of two. See: https://stackoverflow.com/a/108360/5589776
    assert((alignment & (alignment - 1)) == 0);
    auto tc = get_tcache_id_for_calling_thread();
    // Normal Re-allocation with jemalloc (which cannot handle size = 0)
    *ptr = je_rallocx(*ptr, new_size,
                   MALLOCX_ALIGN(alignment) | MALLOCX_ARENA(arena_index) | MALLOCX_TCACHE(tc));

    if (*ptr == nullptr) {
        return Status(StatusCode::OutOfMemory,
                             "HugePageMemoryPool could not Reallocate as requested!");
    }

    auto n_new_bytes = (new_size - old_size);
    if (n_new_bytes >= 0) {
        total_bytes_allocated_ += n_new_bytes;
    }
    bytes_allocated_ += n_new_bytes;

    return Status::OK();
}

void HugePageMemoryPool::free(void *ptr, size_t size, size_t alignment) {
    if (ptr == ZeroSizePointer) {
        assert(size == 0);
    } else {
        bytes_allocated_ -= size;
        num_allocs_ -= 1;
        auto tc = get_tcache_id_for_calling_thread();
        je_dallocx(ptr, MALLOCX_ARENA(arena_index) | MALLOCX_TCACHE(tc));
    }
}

void *HugePageMemoryPool::huge_page_alloc(extent_hooks_t *hooks,
                                          void *new_addr,
                                          size_t size,
                                          size_t alignment,
                                          bool *zero,
                                          bool *commit,
                                          unsigned arena_ind) {
    // When new_addr is != null, the man page says to return new_addr.
    // -> Unclear what the intended behavior is (not documented)
    // -> Ensure it is never NULL since we don't handle that case...
    assert(new_addr == nullptr);

    allocations_mutex_.lock();

    // Check if there is enough space to fit the requested size with alignment
    auto aligned_address = std::align(
        alignment,
        size,
        next_free_addr,
        // Note: std::align decreases remaining_capacity automatically by the alignment bytes!
        remaining_capacity);

    // There was not enough space remaining
    if (aligned_address == nullptr) {
        allocations_mutex_.unlock();
        std::cerr << "HugePageMemoryPool: Not enough huge page memory remaining to satisfy "
                     "jemalloc request over "
                  << size << " bytes. Please add additional 1GiB huge pages to your system."
                  << std::endl;
        return nullptr;
    }

    // There was enough space: Update values
    remaining_capacity -= size;
    next_free_addr = static_cast<void *>(static_cast<std::byte *>(aligned_address) + size);

    // MAP_ANONYMOUS always ensures zero-ing of the memory and only returned commit memory
    *zero   = true;
    *commit = true;
    allocations_mutex_.unlock();
    return aligned_address;
}

bool HugePageMemoryPool::huge_page_dealloc(
    extent_hooks_t *hooks, void *addr, size_t size, bool committed, unsigned arena_ind) {
    // True = opt out from deallocation and retain the memory for future use
    return true;
}

bool HugePageMemoryPool::huge_page_decommit(extent_hooks_t *hooks,
                                            void *addr,
                                            size_t size,
                                            size_t offset,
                                            size_t length,
                                            unsigned arena_ind) {
    // True = Opt out from decommit
    return true;
}

bool HugePageMemoryPool::huge_page_split_extend(extent_hooks_t *hooks,
                                                void *addr,
                                                size_t size,
                                                size_t size_a,
                                                size_t size_b,
                                                bool committed,
                                                unsigned arena_ind) {
    // False = Pages are successfully splitted
    // -> We don't really need to do anything, everything remains in one big chunk.
    return false;
}

bool HugePageMemoryPool::huge_page_merge_extend(extent_hooks_t *hooks,
                                                void *addr_a,
                                                size_t size_a,
                                                void *addr_b,
                                                size_t size_b,
                                                bool committed,
                                                unsigned arena_ind) {
    // False = Successfully merged extends
    // Since all extends given to jemalloc are already continuous, we can always return false
    return false;
}

// ----------------------------------------------------------------------------
// SimpleMemoryPool implementation
// ----------------------------------------------------------------------------

SimpleMemoryPool::~SimpleMemoryPool() {
    std::lock_guard<std::recursive_mutex> lock(allocated_buffers_mutex);
    while (!allocated_buffers.empty()) {
        auto &[ptr, size] = *allocated_buffers.begin();
        free(ptr, size);
    }
}

Status SimpleMemoryPool::allocate(size_t size, size_t alignment, void **out) {
    if (size == 0) {
        *out = nullptr;
    } else {
        // Ensure the alignment is a power of two. See: https://stackoverflow.com/a/108360/5589776
        assert((alignment & (alignment - 1)) == 0);
        *out = std::aligned_alloc(alignment, size);
        if (!out) {
            return Status(StatusCode::OutOfMemory, "Unable to allocate memory!");
        }

        total_bytes_allocated_ += size;
        bytes_allocated_ += size;
    }

    {
        std::lock_guard<std::recursive_mutex> lock(allocated_buffers_mutex);
        allocated_buffers.emplace(*out, size);
    }
    num_allocs_++;

    return Status::OK();
}

Status SimpleMemoryPool::reallocate(size_t old_size, size_t new_size, size_t alignment, void **ptr) {
    if (new_size == 0) {
        free(*ptr, old_size, alignment);
        *ptr = nullptr;
        return Status::OK();
    }

    void* new_ptr = nullptr;
    auto status = allocate(new_size, alignment, &new_ptr);
    if (!status.ok()) {
        return status;
    }

    if (*ptr) {
        std::memcpy(new_ptr, *ptr, std::min(old_size, new_size));
        free(*ptr, old_size, alignment);
    }

    auto n_new_bytes = (new_size - old_size);
    if (n_new_bytes >= 0) {
        total_bytes_allocated_ += n_new_bytes;
    }
    bytes_allocated_ += n_new_bytes;

    *ptr = new_ptr;
    return Status::OK();
}

void SimpleMemoryPool::free(void *ptr, size_t size, size_t alignment) {
    if (ptr) {
        bytes_allocated_ -= size;
        num_allocs_ -= 1;
        std::free(ptr);

        std::lock_guard<std::recursive_mutex> lock(allocated_buffers_mutex);
        allocated_buffers.erase(ptr);
    }
}

std::pair<void *, size_t> SimpleMemoryPool::get_page_boundaries(const void *ptr) {
    std::lock_guard<std::recursive_mutex> lock(allocated_buffers_mutex);
    if (allocated_buffers.find((void *) ptr) == allocated_buffers.end()) {
        std::ostringstream err;
        err << "The Provided address " << ptr << " is not within the bounds of the memory pool!";
        throw std::runtime_error(err.str());
    }

    return std::make_pair((void *) ptr, allocated_buffers[(void *) ptr]);
}

}  // namespace libstf
