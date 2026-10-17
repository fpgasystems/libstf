#pragma once

#include <cmath>
#include <cstdint>
#include <ostream>
#include <unordered_set>
#include <vector>

#include <coyote/cThread.hpp>

#include <libstf/buffer.hpp>
#include <libstf/common.hpp>
#include <libstf/util.hpp>

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

std::ostream &operator<<(std::ostream &out, const ConfigRegister &conf);
std::ostream &operator<<(std::ostream &out, const std::vector<ConfigRegister> &conf);

class Config {
  public:
    Config(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset, uint32_t num_regs);

    /**
     * Read configuration value from addr starting at addr_offset.
     */
    ConfigRegister read_register(uint32_t addr);

    void write_register(ConfigRegister reg);

    static constexpr uint64_t ID = -1;

  protected:
    std::shared_ptr<coyote::cThread> cthread;
    uint32_t                         addr_offset;
    uint32_t                         num_regs;
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
    bool has_config(uint64_t config_id);

    /**
     * Get's the address range of a config with the given config_id.
     */
    std::pair<uint32_t, uint32_t> get_config_bounds(uint64_t config_id);

    uint64_t system_id() { return system_id_; }

    template <typename T> std::shared_ptr<T> get_config() {
        static_assert(std::is_base_of_v<Config, T>, "T must derive from libstf::Config");

        auto it = configs_.find(T::ID);
        if (it == configs_.end()) {
            if (!has_config(T::ID)) {
                auto name = demangle_type_name(typeid(T).name());
                throw std::runtime_error("Hardware design on device has no configuration " + name +
                                         "(ID=" + std::to_string(T::ID) +
                                         ") which we were trying to get");
            }

            auto bounds      = get_config_bounds(T::ID);
            auto addr_offset = std::get<0>(bounds);
            auto num_regs    = std::get<1>(bounds) - addr_offset;
            configs_[T::ID]  = std::make_shared<T>(cthread, addr_offset, num_regs);
        }

        return std::static_pointer_cast<T>(configs_[T::ID]);
    }

  private:
    uint64_t system_id_;
    uint32_t num_configs_;

    std::vector<uint64_t>                                 config_ids;
    std::vector<uint32_t>                                 config_bounds;
    std::unordered_map<uint64_t, std::shared_ptr<Config>> configs_;
};

class MemConfig : public Config {
  public:
    MemConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset, uint32_t num_regs);

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

    const size_t maximum_num_enqueued_buffers() const { return maximum_num_enqueued_buffers_; }

    const bool empty_stream_consumes_buffer() const { return empty_stream_consumes_buffer_; }

    static constexpr uint64_t ID = 0;

  private:
    stream_t num_streams_;
    size_t   maximum_num_enqueued_buffers_;
    bool     empty_stream_consumes_buffer_;
};

class StreamConfig : public Config {
  public:
    StreamConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset, uint32_t num_regs);

    void enqueue_stream_config(stream_t stream_id, type_t type, uint8_t select);

    const stream_t num_streams() const { return num_streams_; }

    static constexpr uint64_t ID = 1;

  private:
    stream_t num_streams_;
};

class ReplayBufferConfig : public Config {
  public:
    ReplayBufferConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                       uint32_t num_regs);

    /**
     * Configures the card memory ring buffer of a ReplayBuffer. This must only be done while the
     * ReplayBuffer is idle, i.e., when all its streams were read the configured number of times.
     * @param buffer_id The ReplayBuffer to configure
     * @param vaddr The start of the ring buffer in card memory. Must be aligned to
     *              MEMORY_ALIGNMENT_BYTES.
     * @param size The size of the ring buffer in bytes. Must fit at least two transfers of the
     *             ReplayBuffer, see transfer_size().
     * @throws std::invalid_argument if the ring buffer does not fulfill these requirements
     */
    void configure_ring_buffer(uint32_t buffer_id, uint64_t vaddr, uint64_t size);

    /**
     * Sets how often the next stream of a ReplayBuffer is read. Every stream needs one value, in
     * stream order. At most maximum_num_enqueued_streams() values can be enqueued. A stream that
     * is read more than once has to fit into the ring buffer.
     * @param buffer_id The ReplayBuffer to configure
     * @param num_reads How often the next stream is read. Must be at least 1.
     */
    void enqueue_num_reads(uint32_t buffer_id, uint32_t num_reads);

    const uint32_t num_buffers() const { return num_buffers_; }

    const size_t maximum_num_enqueued_streams() const { return maximum_num_enqueued_streams_; }

    /**
     * The ReplayBuffers fill their ring buffers one transfer of this many bytes at a time.
     */
    const size_t transfer_size() const { return transfer_size_; }

    static constexpr uint64_t ID = 2;

  private:
    uint32_t num_buffers_;
    size_t   maximum_num_enqueued_streams_;
    size_t   transfer_size_;
};

} // namespace libstf
