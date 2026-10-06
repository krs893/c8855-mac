#pragma once
#include <cstdint>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <nlohmann/json.hpp>

namespace c8855 {
using Json = nlohmann::json;
class APIError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};
struct Sample {
    std::string session_id;
    std::uint64_t sequence;
    std::uint32_t counts;
    double gate_seconds;
    double counts_per_second;
    double received_unix_seconds;
    static Sample from_event(const Json& event);
};
// One receiver per stream. Network I/O runs on its own thread, with a bounded queue.
class Stream {
public:
    ~Stream();
    Stream(Stream&&) noexcept;
    Stream& operator=(Stream&&) noexcept;
    Stream(const Stream&) = delete;
    Stream& operator=(const Stream&) = delete;
    Json next(); // status/sample/heartbeat; throws on disconnect, invalid data, or overflow.
    void close() noexcept; // Stops receiving only. Does not stop USB measurement.
private:
    friend class Client;
    struct Impl;
    std::unique_ptr<Impl> impl_;
    Stream(const std::string& base, long timeout_ms);
};
class Client {
public:
    explicit Client(std::uint16_t port = 8855, long timeout_ms = 10000);
    Json status() const;
    Json probe() const;
    Json start(double gate_seconds = 0.1, std::optional<double> duration_seconds = std::nullopt) const;
    Json stop(bool wait = true) const;
    Stream stream() const; // Open this BEFORE start(), so early samples are not missed.
private:
    std::string base_;
    long timeout_ms_;
    Json request(const std::string& path, const Json* body = nullptr) const;
};
} // namespace c8855
