#include <libstf/configuration.hpp>

#include <cstdio>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>

namespace libstf {

// -------------------------------------------------------------------------------------------------
// ConfigRegister
// -------------------------------------------------------------------------------------------------

ConfigRegister::ConfigRegister(uint32_t addr, uint64_t value) : addr_(addr), value_(value) {}

const uint32_t ConfigRegister::addr() const { return addr_; }

const uint64_t ConfigRegister::value() const { return value_; }

void ConfigRegister::set_value(uint64_t value) { this->value_ = value; }

std::ostream &operator<<(std::ostream &out, const ConfigRegister &conf) {
    out << "FPGAConfiguration { .addr = " << conf.addr() << " .value = 0x";
    // Print the value as hex
    std::ios oldState(nullptr);
    oldState.copyfmt(out);
    out << std::hex;
    out << conf.value();
    out.copyfmt(oldState);
    out << " }";
    return out;
}

std::ostream &operator<<(std::ostream &out, const std::vector<ConfigRegister> &conf) {
    out << "[" << std::endl;
    for (auto config_it = conf.begin(); config_it < conf.end(); config_it++) {
        out << *config_it;
        int index = std::distance(conf.begin(), config_it);
        if (index < conf.size() - 1) {
            out << "," << std::endl;
        }
    }
    out << std::endl << "]" << std::endl;
    return out;
}

// -------------------------------------------------------------------------------------------------
// Config
// -------------------------------------------------------------------------------------------------

Config::Config(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset, uint32_t num_regs)
    : cthread(cthread), addr_offset(addr_offset), num_regs(num_regs) {}

ConfigRegister Config::read_register(uint32_t addr) {
    assert(addr < num_regs);
    return ConfigRegister(addr_offset + addr, cthread->getCSR(addr_offset + addr));
}

void Config::write_register(ConfigRegister reg) {
    assert(reg.addr() < num_regs);
    cthread->setCSR(reg.value(), addr_offset + reg.addr());
}

// -------------------------------------------------------------------------------------------------
// GlobalConfig
// -------------------------------------------------------------------------------------------------

GlobalConfig::GlobalConfig(std::shared_ptr<coyote::cThread> cthread) : Config(cthread, 0, -1) {
    system_id_   = read_register(0).value();
    num_configs_ = read_register(1).value();

    config_bounds.emplace_back(2 + num_configs_);

    for (size_t i = 0; i < num_configs_; i++) {
        config_bounds.emplace_back(read_register(2 + i).value());

        auto config_id = read_register(config_bounds[i]).value();
        assert(!has_config(config_id));
        config_ids.emplace_back(config_id);
    }
}

std::pair<uint32_t, uint32_t> GlobalConfig::get_config_bounds(uint64_t config_id) {
    auto it = std::find(config_ids.begin(), config_ids.end(), config_id);
    assert(it != config_ids.end());

    auto config_idx = std::distance(config_ids.begin(), it);

    return std::pair<uint32_t, uint32_t>(config_bounds[config_idx], config_bounds[config_idx + 1]);
}

bool GlobalConfig::has_config(uint64_t config_id) {
    auto it = std::find(config_ids.begin(), config_ids.end(), config_id);
    return it != config_ids.end();
}

// -------------------------------------------------------------------------------------------------
// MemConfig
// -------------------------------------------------------------------------------------------------

MemConfig::MemConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                     uint32_t num_regs)
    : Config(cthread, addr_offset, num_regs), num_streams_(read_register(1).value()),
      maximum_num_enqueued_buffers_(read_register(2).value()) {}

void MemConfig::enqueue_buffer(stream_t stream_id, Buffer &buffer) {
    assert(stream_id < num_streams_);

    auto vaddr = reinterpret_cast<size_t>(buffer.ptr);

    // Assert the buffer properties. The design only supports buffers that are a multiple of the
    // transfer size.
    assert(vaddr < (1ULL << FPGA_VADDR_BITS));
    assert(buffer.capacity > 0);
    assert(buffer.capacity < MAXIMUM_FPGA_BUFFER_SIZE);
    assert(buffer.capacity % BYTES_PER_FPGA_TRANSFER == 0);

    size_t capacity_as_num_transfers = buffer.capacity / BYTES_PER_FPGA_TRANSFER;

    write_register(
        ConfigRegister(stream_id, vaddr << BUFFER_SIZE_BITS | capacity_as_num_transfers));
}

// -------------------------------------------------------------------------------------------------
// StreamConfig
// -------------------------------------------------------------------------------------------------

StreamConfig::StreamConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                           uint32_t num_regs)
    : Config(cthread, addr_offset, num_regs), num_streams_(read_register(1).value()) {}

void StreamConfig::enqueue_stream_config(stream_t stream_id, type_t type, uint8_t select) {
    assert(stream_id < num_streams_);

    write_register(ConfigRegister(stream_id, (select << 3) | static_cast<uint8_t>(type)));
}

// -------------------------------------------------------------------------------------------------
// ReplayBufferConfig
// -------------------------------------------------------------------------------------------------

ReplayBufferConfig::ReplayBufferConfig(std::shared_ptr<coyote::cThread> cthread,
                                       uint32_t addr_offset, uint32_t num_regs)
    : Config(cthread, addr_offset, num_regs), num_buffers_(read_register(1).value()),
      maximum_num_enqueued_streams_(read_register(2).value()),
      transfer_size_(read_register(3).value()) {}

void ReplayBufferConfig::configure_ring_buffer(uint32_t buffer_id, uint64_t vaddr, uint64_t size) {
    assert(buffer_id < num_buffers_);

    // A misconfigured ring buffer makes the hardware hang, so we check it in release builds too
    if (vaddr + size > (1ULL << FPGA_VADDR_BITS)) {
        throw std::invalid_argument("Ring buffer exceeds the vaddr space");
    }
    if (vaddr % MEMORY_ALIGNMENT_BYTES != 0) {
        throw std::invalid_argument("Ring buffer must be aligned to " +
                                    std::to_string(MEMORY_ALIGNMENT_BYTES) + " bytes");
    }
    if (size < 2 * transfer_size_) {
        throw std::invalid_argument("Ring buffer must fit at least two transfers of " +
                                    std::to_string(transfer_size_) + " bytes");
    }

    // Writing the size commits the configuration, so it has to be written last
    write_register(ConfigRegister(3 * buffer_id, vaddr));
    write_register(ConfigRegister(3 * buffer_id + 1, size));
}

void ReplayBufferConfig::enqueue_num_reads(uint32_t buffer_id, uint32_t num_reads) {
    assert(buffer_id < num_buffers_);
    assert(num_reads > 0);

    write_register(ConfigRegister(3 * buffer_id + 2, num_reads));
}

} // namespace libstf
