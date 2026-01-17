#pragma once

#include <mutex>
#include <set>

#include "coyote/cThread.hpp"

#include "libstf/memory_pool.hpp"

namespace libstf {

/**
 * The TLB manager is responsible for ensuring that allocated pages are mapped to the FPGA's TLB. I 
 * also unmaps the pages upon destruction.
 * 
 * Note: This does not work when the TLB becomes full and TLB entries are evicted. It is intended to
 * be used with 1GiB huge pages. With the standard Coyote TLB configuration, this allows to map 
 * 512GiB of memory.
 */
class TLBManager {
public:
    TLBManager(std::shared_ptr<coyote::cThread> cthread, std::shared_ptr<MemoryPool> memory_pool);

    ~TLBManager();

    /**
    * Ensures a TLB mapping on the FPGA exists for the given address and size. If the address was 
    * already mapped previously, no new mapping will be created. It is assumed, that the given 
    * address was allocated using a memory pool based on MemoryPool.
    * 
    * Note: We could also just always call cThread::userMap(...) but that invokes a system call 
    * which we want to avoid for performance reasons.
    * 
    * @param data_address Address that points to the beginning of the data
    * @param size The size of the data to be mapped in bytes.
    */
    void ensure_tlb_mapping(const void *data_address, size_t size);

private:
    std::shared_ptr<coyote::cThread> cthread;
    std::shared_ptr<MemoryPool> memory_pool;

    // The address of all the pages for which we already performed a TLB mapping
    std::set<void *> existing_tlb_mappings;
    std::recursive_mutex tlb_mutex;
};

}  // namespace libstf
