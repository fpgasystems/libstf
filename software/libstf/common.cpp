#include <libstf/common.hpp>

namespace libstf {

std::ostream &operator<<(std::ostream &out, const type_t &data_type) {
    switch (data_type) {
    case type_t::BYTE_T:
        out << "type_t::BYTE_T";
        break;
    case type_t::INT32_T:
        out << "type_t::INT32_T";
        break;
    case type_t::INT64_T:
        out << "type_t::INT64_T";
        break;
    case type_t::FLOAT_T:
        out << "type_t::FLOAT_T";
        break;
    case type_t::DOUBLE_T:
        out << "type_t::DOUBLE_T";
        break;
    case type_t::INT16_T:
        out << "type_t::INT16_T";
        break;
    case type_t::INT128_T:
        out << "type_t::INT128_T";
        break;
    case type_t::NUM_TYPES:
        out << "type_t::NUM_TYPES";
        break;
    }
    return out;
}

} // namespace libstf

std::ostream &operator<<(std::ostream &out, const libstf::Value &v) {
    std::visit([&out](auto &&val) { out << val; }, v);
    return out;
}
