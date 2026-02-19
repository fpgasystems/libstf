#pragma once

#include <ostream>
#include <variant>

namespace libstf {

// -- Utils ----------------------------------------------------------------------------------------

// Problem: while std::log2 exists, it is only a const_expression in gcc, not in clang.
// Therefore, using it might not compile under all scenarios.
// Solution: Re-define our down constexpr for a floored log2.
// Inspired by: https://stackoverflow.com/a/35313613/5589776
// Same implementation logic as in the SV code. See:
// https://gitlab.inf.ethz.ch/OU-ALONSO/Student-Projects/fpga-dbops/-/blob/main/src/hdl/common.sv?ref_type=heads#L12
constexpr unsigned floor_log2(unsigned val) {
    return val ? 1 + floor_log2(val >> 1) : -1;
}

// -- Constants ------------------------------------------------------------------------------------

// Memory
static constexpr uint32_t BYTES_PER_FPGA_TRANSFER      = 65536;
static constexpr uint32_t FPGA_VADDR_BITS              = 48;
static constexpr uint32_t INTERRUPT_TRANSFER_SIZE_BITS = 28;
static constexpr uint32_t BUFFER_SIZE_BITS             = INTERRUPT_TRANSFER_SIZE_BITS - floor_log2(BYTES_PER_FPGA_TRANSFER);
static constexpr uint32_t MAXIMUM_FPGA_BUFFER_SIZE     = (1 << INTERRUPT_TRANSFER_SIZE_BITS) - 1;

static constexpr uint32_t MAXIMUM_FPGA_NUM_STREAMS          = 64;
static_assert(MAXIMUM_FPGA_NUM_STREAMS <= 64);
static constexpr uint32_t FPGA_INTERRUPT_STREAM_ID_BITS     = 3;
static constexpr uint32_t FPGA_INTERRUPT_TRANSFER_SIZE_BITS = 28;
static constexpr uint32_t FPGA_INTERRUPT_LAST_BITS          = 1;

// -- Type defs ------------------------------------------------------------------------------------
typedef uint8_t stream_t; // Type that holds a stream_id

enum class type_t : unsigned char { 
    BYTE_T,
    INT32_T,
    INT64_T,
    FLOAT_T,
    DOUBLE_T,
    NUM_TYPES
};

std::ostream &operator<<(std::ostream &out, const type_t &data_type);

constexpr size_t size_of(type_t type) {
    switch (type) {
        case type_t::BYTE_T:   return 1;
        case type_t::INT32_T:  return 4;
        case type_t::INT64_T:  return 8;
        case type_t::FLOAT_T:  return 4;
        case type_t::DOUBLE_T: return 8;
        case type_t::NUM_TYPES: break;
    }
    throw std::invalid_argument("Invalid type");
}

/**
 * Type dispatcher for type_t. This assumes you pass it a struct with an operator as the Func.
 */
template <typename Func, typename... Args>
auto dispatch_type(libstf::type_t type, Func &&func, Args &&... args) {
    switch (type) {
        case libstf::type_t::BYTE_T:
            return func.template operator()<std::byte>(std::forward<Args>(args)...);
        case libstf::type_t::INT32_T:
            return func.template operator()<int32_t>(std::forward<Args>(args)...);
        case libstf::type_t::INT64_T:
            return func.template operator()<int64_t>(std::forward<Args>(args)...);
        case libstf::type_t::FLOAT_T:
            return func.template operator()<float>(std::forward<Args>(args)...);
        case libstf::type_t::DOUBLE_T:
            return func.template operator()<double>(std::forward<Args>(args)...);
        case type_t::NUM_TYPES: break;
    }
    throw std::invalid_argument("Invalid type");
}

using Value = std::variant<std::byte, int32_t, int64_t, float, double>;

} // namespace celeris

// If this is not defined in the global namespace, we cannot find it in Celeris
std::ostream &operator<<(std::ostream &out, const libstf::Value &v);
