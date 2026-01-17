#include "libstf/tlb_manager.hpp"

namespace libstf {

// ----------------------------------------------------------------------------
// Public methods
// ----------------------------------------------------------------------------

TLBManager::TLBManager(std::shared_ptr<coyote::cThread> cthread, std::shared_ptr<MemoryPool> memory_pool)
        : memory_pool(memory_pool)
        , cthread(cthread) {}

TLBManager::~TLBManager() {
    std::lock_guard tlb_guard(tlb_mutex);

    // Unmap all tlb entries we have created on the FPGA
    for (const auto& mapping : existing_tlb_mappings) {
        cthread->userUnmap(mapping);
    }
}

void TLBManager::ensure_tlb_mapping(const void *data_address, size_t size) {
    // Guard the tlb_mapping structures. Note: This uses a recursive mutex!
    std::lock_guard guard(tlb_mutex);

    auto [page_address, page_size] =
        memory_pool->get_page_boundaries(data_address);
    // Check if this mapping already exists
    if (existing_tlb_mappings.find(page_address) == existing_tlb_mappings.end()) {
        // Add new TLB entry for this page!
        cthread->userMap(page_address, page_size);
        existing_tlb_mappings.insert(page_address);
    }

    auto end_mapped = static_cast<const std::byte *>(data_address) + size;
    auto page_end   = static_cast<const std::byte *>(page_address) + page_size;

    // Check if the size goes over one page and further pages need to be mapped
    if (end_mapped > page_end) {
        ensure_tlb_mapping(static_cast<const void *>(page_end), end_mapped - page_end);
    }
}

}  // namespace libstf
