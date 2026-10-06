#include "c8855_client.hpp"
#include <curl/curl.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <deque>
#include <exception>
#include <limits>
#include <mutex>
#include <sstream>
#include <thread>

namespace c8855 {
namespace {
struct CurlRuntime {
    CurlRuntime() { if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) throw APIError("libcurl initialization failed"); }
    ~CurlRuntime() { curl_global_cleanup(); }
};
using Curl = std::unique_ptr<CURL, decltype(&curl_easy_cleanup)>;
Curl make_curl(const std::string& url, long timeout_ms) {
    static CurlRuntime runtime;
    Curl curl(curl_easy_init(), curl_easy_cleanup);
    if (!curl) throw APIError("Cannot create HTTP client");
    curl_easy_setopt(curl.get(), CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl.get(), CURLOPT_PROXY, "");
    curl_easy_setopt(curl.get(), CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl.get(), CURLOPT_CONNECTTIMEOUT_MS, timeout_ms);
    curl_easy_setopt(curl.get(), CURLOPT_FOLLOWLOCATION, 0L);
    return curl;
}
struct Body { std::string text; std::exception_ptr error; };
std::size_t collect_body(char* data, std::size_t size, std::size_t count, void* context) noexcept {
    auto& body = *static_cast<Body*>(context);
    const auto bytes = size * count;
    try {
        if (body.text.size() + bytes > 1048576) throw APIError("API response too large");
        body.text.append(data, bytes);
        return bytes;
    } catch (...) { body.error = std::current_exception(); return 0; }
}
std::uint64_t unsigned_field(const Json& event, const char* field, std::uint64_t max) {
    const auto& value = event.at(field);
    if (!value.is_number_integer() || (!value.is_number_unsigned() && value.get<std::int64_t>() < 0))
        throw APIError(std::string("Invalid integer: ") + field);
    const auto number = value.get<std::uint64_t>();
    if (number > max) throw APIError(std::string("Integer out of range: ") + field);
    return number;
}
double numeric_field(const Json& event, const char* field) {
    const auto& value = event.at(field);
    if (!value.is_number()) throw APIError(std::string("Invalid number: ") + field);
    const double number = value.get<double>();
    if (!std::isfinite(number) || number < 0) throw APIError(std::string("Invalid number: ") + field);
    return number;
}
} // namespace
Sample Sample::from_event(const Json& event) {
    if (event.at("type") != "sample") throw APIError("Event is not a sample");
    Sample sample{event.at("session_id").get<std::string>(),
                  unsigned_field(event, "sample", std::numeric_limits<std::uint64_t>::max()),
                  static_cast<std::uint32_t>(unsigned_field(event, "counts", std::numeric_limits<std::uint32_t>::max())),
                  numeric_field(event, "gate_seconds"), numeric_field(event, "counts_per_second"),
                  numeric_field(event, "received_unix_seconds")};
    if (sample.session_id.empty() || sample.sequence == 0 || sample.gate_seconds <= 0)
        throw APIError("Invalid sample metadata");
    return sample;
}
Client::Client(std::uint16_t port, long timeout_ms) :
    base_("http://127.0.0.1:" + std::to_string(port) + "/api"), timeout_ms_(timeout_ms) {
    if (port == 0 || timeout_ms <= 0) throw APIError("Invalid port or timeout");
}
Json Client::request(const std::string& path, const Json* body) const {
    auto curl = make_curl(base_ + path, timeout_ms_);
    curl_easy_setopt(curl.get(), CURLOPT_TIMEOUT_MS, timeout_ms_);
    Body response;
    curl_easy_setopt(curl.get(), CURLOPT_WRITEFUNCTION, collect_body);
    curl_easy_setopt(curl.get(), CURLOPT_WRITEDATA, &response);
    std::unique_ptr<curl_slist, decltype(&curl_slist_free_all)> headers(nullptr, curl_slist_free_all);
    std::string payload;
    if (body) {
        payload = body->dump();
        headers.reset(curl_slist_append(nullptr, "Content-Type: application/json"));
        if (!headers) throw APIError("Cannot create request headers");
        curl_easy_setopt(curl.get(), CURLOPT_HTTPHEADER, headers.get());
        curl_easy_setopt(curl.get(), CURLOPT_POSTFIELDS, payload.c_str());
        curl_easy_setopt(curl.get(), CURLOPT_POSTFIELDSIZE, static_cast<long>(payload.size()));
    }
    const auto result = curl_easy_perform(curl.get());
    if (response.error) std::rethrow_exception(response.error);
    if (result != CURLE_OK) throw APIError(std::string("API connection failed: ") + curl_easy_strerror(result));
    auto json = Json::parse(response.text);
    long code = 0; curl_easy_getinfo(curl.get(), CURLINFO_RESPONSE_CODE, &code);
    if (code < 200 || code >= 300) throw APIError(json.value("error", "HTTP " + std::to_string(code)));
    if (!json.is_object()) throw APIError("Invalid API response");
    return json;
}
Json Client::status() const { return request("/status"); }
Json Client::probe() const { const Json body = Json::object(); return request("/probe", &body); }
Json Client::start(double gate, std::optional<double> duration) const {
    if (!(gate == 0.01 || gate == 0.02 || gate == 0.05 || gate == 0.1 || gate == 0.2 || gate == 0.5 || gate == 1.0)) throw APIError("Invalid gate time");
    Json body = {{"gate_seconds", gate}};
    if (duration) {
        if (!std::isfinite(*duration) || *duration < 1 || *duration > 3600) throw APIError("Invalid duration");
        body["duration_seconds"] = *duration;
    }
    return request("/start", &body);
}
Json Client::stop(bool wait) const {
    const Json body = Json::object();
    auto state = request("/stop", &body);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms_);
    while (wait && state.at("running").get<bool>()) {
        if (std::chrono::steady_clock::now() >= deadline) throw APIError("Stop completion timed out");
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        state = status();
    }
    if (wait && !state.at("error").get<std::string>().empty()) throw APIError(state.at("error").get<std::string>());
    return state;
}
struct Stream::Impl {
    std::string base;
    long timeout_ms;
    std::atomic<bool> cancelled{false};
    std::thread worker;
    std::mutex mutex;
    std::condition_variable condition;
    std::deque<Json> events;
    bool ready = false, finished = false;
    std::exception_ptr error;
    long code = 0;
    std::string line;
    Impl(std::string url, long timeout) : base(std::move(url)), timeout_ms(timeout) {}
    ~Impl() { close(); }
    void close() noexcept {
        cancelled.store(true); condition.notify_all();
        if (worker.joinable()) worker.join();
    }
    void fail(std::exception_ptr reason) {
        std::lock_guard<std::mutex> lock(mutex);
        if (!error) error = reason;
        condition.notify_all();
    }
    static std::size_t header(char* data, std::size_t size, std::size_t count, void* context) noexcept {
        auto& self = *static_cast<Impl*>(context);
        const auto bytes = size * count;
        try {
            const std::string text(data, bytes);
            if (text.rfind("HTTP/", 0) == 0) { std::istringstream input(text); std::string protocol; input >> protocol >> self.code; }
            if (text == "\r\n") {
                if (self.code != 200) throw APIError("Stream rejected: HTTP " + std::to_string(self.code));
                std::lock_guard<std::mutex> lock(self.mutex); self.ready = true; self.condition.notify_all();
            }
            return bytes;
        } catch (...) { self.fail(std::current_exception()); return 0; }
    }
    static std::size_t data(char* data, std::size_t size, std::size_t count, void* context) noexcept {
        auto& self = *static_cast<Impl*>(context);
        const auto bytes = size * count;
        try {
            for (std::size_t i = 0; i < bytes; ++i) {
                if (data[i] != '\n') {
                    if (self.line.size() >= 65536) throw APIError("Stream line too large");
                    self.line.push_back(data[i]);
                } else {
                    auto event = Json::parse(self.line); self.line.clear();
                    if (!event.is_object() || !event.contains("type") || !event["type"].is_string()) throw APIError("Invalid stream event");
                    std::lock_guard<std::mutex> lock(self.mutex);
                    if (self.events.size() >= 256) throw APIError("Receiver queue overflow; check missing samples");
                    self.events.push_back(std::move(event)); self.condition.notify_all();
                }
            }
            return bytes;
        } catch (...) { self.fail(std::current_exception()); return 0; }
    }
    static int progress(void* context, curl_off_t, curl_off_t, curl_off_t, curl_off_t) noexcept {
        return static_cast<Impl*>(context)->cancelled.load() ? 1 : 0;
    }
    void run() noexcept {
        try {
            auto curl = make_curl(base + "/stream", timeout_ms);
            curl_easy_setopt(curl.get(), CURLOPT_LOW_SPEED_LIMIT, 1L);
            curl_easy_setopt(curl.get(), CURLOPT_LOW_SPEED_TIME, 10L);
            curl_easy_setopt(curl.get(), CURLOPT_HEADERFUNCTION, header);
            curl_easy_setopt(curl.get(), CURLOPT_HEADERDATA, this);
            curl_easy_setopt(curl.get(), CURLOPT_WRITEFUNCTION, data);
            curl_easy_setopt(curl.get(), CURLOPT_WRITEDATA, this);
            curl_easy_setopt(curl.get(), CURLOPT_NOPROGRESS, 0L);
            curl_easy_setopt(curl.get(), CURLOPT_XFERINFOFUNCTION, progress);
            curl_easy_setopt(curl.get(), CURLOPT_XFERINFODATA, this);
            const auto result = curl_easy_perform(curl.get());
            if (!cancelled.load()) {
                if (result == CURLE_OK) throw APIError("Stream disconnected; check missing samples");
                throw APIError(std::string("Stream failed: ") + curl_easy_strerror(result));
            }
        } catch (...) { fail(std::current_exception()); }
        { std::lock_guard<std::mutex> lock(mutex); finished = true; condition.notify_all(); }
    }
    void start() {
        worker = std::thread([this] { run(); });
        std::unique_lock<std::mutex> lock(mutex);
        if (!condition.wait_for(lock, std::chrono::milliseconds(timeout_ms), [this] { return ready || error || finished; }))
            throw APIError("Stream connection timed out");
        if (error) std::rethrow_exception(error);
        if (!ready) throw APIError("Stream did not open");
    }
    Json next() {
        std::unique_lock<std::mutex> lock(mutex);
        condition.wait(lock, [this] { return !events.empty() || error || finished || cancelled.load(); });
        if (!events.empty()) { auto event = std::move(events.front()); events.pop_front(); return event; }
        if (error) std::rethrow_exception(error);
        throw APIError("Stream closed");
    }
};
Stream::Stream(const std::string& base, long timeout) : impl_(std::make_unique<Impl>(base, timeout)) { impl_->start(); }
Stream::~Stream() = default;
Stream::Stream(Stream&&) noexcept = default;
Stream& Stream::operator=(Stream&&) noexcept = default;
Json Stream::next() { if (!impl_) throw APIError("Stream moved or closed"); return impl_->next(); }
void Stream::close() noexcept { if (impl_) impl_->close(); }
Stream Client::stream() const { return Stream(base_, timeout_ms_); }
} // namespace c8855
