#pragma once

#include <cmath>
#include <unordered_set>
#include <vector>
#include <cstdint>
#include <ostream>

#include "coyote/cThread.hpp"

#include "libstf/common.hpp"
#include "libstf/buffer.hpp"

namespace libstf {

class ConfigRegister {
public:
    ConfigRegister(uint32_t addr, uint64_t value);

    void set_value(uint64_t value);

    const uint32_t addr() const;
    const uint64_t value() const;
private:
    uint32_t addr_;
    uint64_t value_;
};

std::ostream& operator<<(std::ostream& out, const ConfigRegister& conf);
std::ostream& operator<<(std::ostream& out, const std::vector<ConfigRegister>& conf);

class Config {
public:
    Config(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset);

    /**
     * Read configuration value from addr starting at addr_offset.
     */
    ConfigRegister read_register(uint32_t addr);

    void write_register(ConfigRegister reg);

    static constexpr uint32_t ID = -1;

private:
    std::shared_ptr<coyote::cThread> cthread;
    uint32_t addr_offset;
};

class GlobalConfig : private Config {
public:
    /**
     * Note: Takes the cThread as a reference so we don't create a circular dependency with 
     * CelerisContext.
     */
    GlobalConfig(std::shared_ptr<coyote::cThread> cthread);

    /**
     * Checks whether a config with a certain config_id is present in the system. Can be used to 
     * check which operators the Celeris instance flashed to the device supports.
     */
    bool has_config(uint32_t config_id);

    /**
     * Get's the address range of a config with the given config_id.
     */
    std::pair<uint32_t, uint32_t> get_config_bounds(uint32_t config_id);

    uint64_t system_id() { return system_id_; }

private:
    uint64_t system_id_;
    uint32_t num_configs_;

    std::vector<uint32_t> config_ids;
    std::vector<uint32_t> config_bounds;
};

class MemConfig : public Config {
public:
    MemConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset);

    /**
     * Writes the CSR registers to add a new buffer to the FPGA for the given stream.
     * @param stream_id The stream this buffer is done for
     * @param buffer The buffer to write the registers for
     */
    void enqueue_buffer(stream_t stream_id, Buffer &buffer);

    /**
     * Writes the flush buffer CSR register which flushes potentially stale buffers in hardware.
     */
    void flush_buffers() { write_register(ConfigRegister(num_streams_, 0)); }

    const stream_t num_streams() const { return num_streams_; }

    static constexpr uint32_t ID = 0;

private:
    stream_t num_streams_;
};

class StreamConfig : public Config {
public:
    static constexpr uint32_t ID = 1;
};

}  // namespace libstf
