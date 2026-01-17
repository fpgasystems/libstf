#pragma once

#include <stdexcept>
#include <string>

namespace libstf {

enum StatusCode {
    OK          = 0,
    OutOfMemory = 2,
    Error       = 3,
};

/**
 * This status class was originally taken from the Maximus project.
 */
class Status {
public:
    Status() = default;

    Status(int code, const std::string &msg) {
        this->_code    = code;
        this->_message = msg;
    }

    explicit Status(int code) { this->_code = code; }

    explicit Status(StatusCode code) { this->_code = code; }

    Status(StatusCode code, const std::string &msg) {
        this->_code    = code;
        this->_message = msg;
    }

    int code() const { return _code; }

    bool ok() const { return _code == StatusCode::OK; }

    static Status OK() { return Status(StatusCode::OK); }

    const std::string &message() const { return _message; }

    std::string to_string() const {
        return "code: " + std::to_string(_code) + ", message: " + _message;
    }

private:
    int _code{};
    std::string _message{};
};

template<typename T>
void check_status(const T &expr) {
    if (!expr.ok()) {
        throw std::runtime_error("Celeris Error: " + std::to_string(static_cast<int>(expr.code())) +
                                 "; Message: " + expr.message() + "\n" + __FILE__ + ":" +
                                 std::to_string(__LINE__));
    }
}

}  // namespace libstf
