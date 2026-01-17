#include "libstf/configuration.hpp"

#include <cstdio>
#include <cstring>
#include <iostream>

namespace libstf {

// ----------------------------------------------------------------------------
// ConfigRegister
// ----------------------------------------------------------------------------

ConfigRegister::ConfigRegister(uint32_t addr, uint64_t value)
        : addr_(addr), value_(value) {
}

const uint32_t ConfigRegister::addr() const {
    return addr_;
}

const uint64_t ConfigRegister::value() const {
    return value_;
}

void ConfigRegister::set_value(uint64_t value) {
    this->value_ = value;
}

std::ostream &operator<<(std::ostream &out, const ConfigRegister &conf) {
    out << "FPGAConfiguration { .addr = " << conf.addr()
        << " .value = 0x";
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

// ----------------------------------------------------------------------------
// Config
// ----------------------------------------------------------------------------

Config::Config(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset) : 
        cthread(cthread), 
        addr_offset(addr_offset) {}

ConfigRegister Config::read_register(uint32_t addr) {
    return ConfigRegister(addr_offset + addr, cthread->getCSR(addr_offset + addr));
}

void Config::write_register(ConfigRegister reg) {
    cthread->setCSR(reg.value(), addr_offset + reg.addr());
}

// ----------------------------------------------------------------------------
// GlobalConfig
// ----------------------------------------------------------------------------

GlobalConfig::GlobalConfig(std::shared_ptr<coyote::cThread> cthread) : Config(cthread, 0) {
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

std::pair<uint32_t, uint32_t> GlobalConfig::get_config_bounds(uint32_t config_id) {
    auto it = std::find(config_ids.begin(), config_ids.end(), config_id);
    assert(it != config_ids.end());
    
    auto config_idx = std::distance(config_ids.begin(), it); 

    return std::pair<uint32_t, uint32_t>(config_bounds[config_idx], config_bounds[config_idx + 1]);
}

bool GlobalConfig::has_config(uint32_t config_id) {
    auto it = std::find(config_ids.begin(), config_ids.end(), config_id);
    return it != config_ids.end();
}

// ----------------------------------------------------------------------------
// MemConfig
// ----------------------------------------------------------------------------

MemConfig::MemConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset) : 
    Config(cthread, addr_offset), 
    num_streams_(read_register(1).value()) {}

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

    write_register(ConfigRegister(stream_id, vaddr << BUFFER_SIZE_BITS | capacity_as_num_transfers));
}

}  // namespace libstf
