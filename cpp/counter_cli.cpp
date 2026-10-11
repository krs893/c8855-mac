#include "c8855_client.hpp"
#include <cerrno>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdio>
#include <fcntl.h>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <optional>
#include <regex>
#include <sstream>
#include <string>
#include <unistd.h>

namespace {
using c8855::Json;
volatile std::sig_atomic_t interrupted = 0;
void interrupt(int signal) { interrupted = signal; }

std::string redact(std::string text) {
    static const std::regex bearer("Bearer[ \\t]+[^ \\t\\r\\n\\\"]+", std::regex::icase);
    static const std::regex assigned("([a-z_]*(token|password|api_key|secret)[a-z_]*[ \\t]*[:=][ \\t]*)[^ \\t\\r\\n,]+", std::regex::icase);
    text = std::regex_replace(text, bearer, "Bearer [redacted]");
    return std::regex_replace(text, assigned, "$1[redacted]");
}
Json safeJSON(Json value) {
    if (value.is_object()) {
        for (auto item = value.begin(); item != value.end(); ++item) {
            std::string key = item.key();
            for (auto& c : key) if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
            if (key.find("token") != std::string::npos || key.find("password") != std::string::npos
                || key.find("secret") != std::string::npos || key == "authorization" || key == "api_key") item.value() = "[redacted]";
            else item.value() = safeJSON(item.value());
        }
    } else if (value.is_array()) { for (auto& item : value) item = safeJSON(item); }
    else if (value.is_string()) value = redact(value.get<std::string>());
    return value;
}
struct Options {
    std::string command, csv;
    double gate = 0.1;
    std::optional<double> duration;
    std::optional<std::uint64_t> samples;
    unsigned port = 8855;
    long timeout = 10000;
};
double number(const char* input) {
    std::size_t used = 0;
    const std::string text(input);
    const double value = std::stod(text, &used);
    if (used != text.size() || !std::isfinite(value)) throw c8855::APIError("Invalid numeric option");
    return value;
}
std::uint64_t integer(const char* input) {
    const std::string text(input);
    if (text.empty() || text.find_first_not_of("0123456789") != std::string::npos) throw c8855::APIError("Invalid integer option");
    return std::stoull(text);
}
void help() {
    std::cout << "c8855_counter status | settings | start | stop | record [options]\n"
              << "  start:  --gate 0.1 [--duration 10] (otherwise continuous)\n"
              << "  record: --gate 0.1 (--duration 10 | --samples 100) --csv counts.csv\n"
              << "  common: --port 8855 --timeout-ms 10000\n"
              << "Record retains all samples received before stop completion, including a final USB batch.\n"
              << "Requires the native C8855 app's local API; no direct USB access.\n";
}
Options parse(int argc, char** argv) {
    if (argc < 2) throw c8855::APIError("Specify status, settings, start, stop, or record; use --help");
    Options o; o.command = argv[1];
    if (o.command != "status" && o.command != "settings" && o.command != "start" && o.command != "stop" && o.command != "record")
        throw c8855::APIError("Unknown command; use --help");
    bool hasGate = false;
    for (int i = 2; i < argc; ++i) {
        const std::string option = argv[i];
        if (i + 1 >= argc) throw c8855::APIError("Incomplete option");
        if (option == "--gate") { o.gate = number(argv[++i]); hasGate = true; }
        else if (option == "--duration") o.duration = number(argv[++i]);
        else if (option == "--samples") o.samples = integer(argv[++i]);
        else if (option == "--csv") o.csv = argv[++i];
        else if (option == "--port") {
            const auto port = integer(argv[++i]);
            if (port < 1 || port > 65535) throw c8855::APIError("Invalid port");
            o.port = static_cast<unsigned>(port);
        } else if (option == "--timeout-ms") {
            const auto timeout = integer(argv[++i]);
            if (timeout < 1 || timeout > 60000) throw c8855::APIError("Timeout must be 1..60000 ms");
            o.timeout = static_cast<long>(timeout);
        } else throw c8855::APIError("Unknown option; use --help");
    }
    const bool acquisition = o.command == "start" || o.command == "record";
    if (!acquisition && (hasGate || o.duration || o.samples || !o.csv.empty())) throw c8855::APIError("Measurement options require start or record");
    if (!(o.gate == 0.01 || o.gate == 0.02 || o.gate == 0.05 || o.gate == 0.1 || o.gate == 0.2 || o.gate == 0.5 || o.gate == 1))
        throw c8855::APIError("Gate must be 0.01/0.02/0.05/0.1/0.2/0.5/1 seconds");
    if (o.duration && (*o.duration < 1 || *o.duration > 3600)) throw c8855::APIError("Duration must be 1..3600 seconds");
    if (o.samples && (*o.samples == 0 || *o.samples > 100000000)) throw c8855::APIError("Samples must be 1..100000000");
    if (o.command == "start" && (o.samples || !o.csv.empty())) throw c8855::APIError("Use record for sample limits and CLI CSV");
    if (o.command == "record" && (o.csv.empty() || o.duration.has_value() == o.samples.has_value()))
        throw c8855::APIError("Record needs --csv and exactly one of --duration or --samples");
    return o;
}
std::string csvCell(const std::string& value) {
    std::string result = "\"";
    for (const char c : value) { if (c == '"') result += '"'; result += c; }
    return result + '"';
}
std::string precise(double value) { std::ostringstream out; out << std::setprecision(17) << value; return out.str(); }
class CSV {
    std::unique_ptr<FILE, decltype(&std::fclose)> file{nullptr, std::fclose};
public:
    std::uint64_t rows = 0;
    explicit CSV(const std::string& path) {
        const int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (fd < 0) throw c8855::APIError(errno == EEXIST ? "CSV exists; choose a new filename" : "Cannot create CSV");
        file.reset(::fdopen(fd, "w"));
        if (!file) { ::close(fd); throw c8855::APIError("Cannot open CSV writer"); }
        write("received_at,sample,gate_seconds,counts,counts_per_second,received_unix_seconds,received_monotonic_seconds,session_id,elapsed_gate_seconds,nominal_block,nominal_index_in_block,nominal_block_size\n");
    }
    void write(const std::string& line) {
        if (std::fwrite(line.data(), 1, line.size(), file.get()) != line.size() || std::fflush(file.get()) != 0)
            throw c8855::APIError("CSV write failed; partial file retained");
    }
    void sample(const Json& event, const c8855::Sample& sample) {
        const auto& received = event.at("received_at");
        if (!received.is_string()) throw c8855::APIError("Invalid received timestamp");
        auto optionalNumber = [&](const char* key) {
            if (!event.contains(key)) return std::string();
            if (!event.at(key).is_number()) throw c8855::APIError("Invalid sample timing metadata");
            const auto value = event.at(key).get<double>();
            if (!std::isfinite(value) || value < 0) throw c8855::APIError("Invalid sample timing metadata");
            return precise(value);
        };
        const auto blockSize = sample.gate_seconds < 0.1 ? static_cast<std::uint64_t>(std::llround(0.1 / sample.gate_seconds)) : 1;
        write(csvCell(received.get<std::string>()) + ',' + std::to_string(sample.sequence) + ',' + precise(sample.gate_seconds) + ','
            + std::to_string(sample.counts) + ',' + precise(sample.counts_per_second) + ',' + precise(sample.received_unix_seconds) + ','
            + optionalNumber("received_monotonic_seconds") + ',' + csvCell(sample.session_id) + ',' + optionalNumber("elapsed_gate_seconds") + ','
            + std::to_string((sample.sequence - 1) / blockSize + 1) + ',' + std::to_string((sample.sequence - 1) % blockSize + 1) + ',' + std::to_string(blockSize) + '\n');
        ++rows;
    }
    void finish() {
        if (std::fflush(file.get()) != 0 || ::fsync(::fileno(file.get())) != 0) throw c8855::APIError("CSV finalization failed; partial file retained");
    }
};
void stopOwn(const c8855::Client& counter, const std::string& session, bool wait) {
    const auto status = counter.status();
    if (status.value("session_id", "") == session && status.value("running", false)) counter.stop(wait, session);
}
int record(const Options& options, const c8855::Client& counter) {
    const auto initial = counter.status();
    if (initial.value("running", false) || initial.value("checking", false)) throw c8855::APIError("Counter is busy; existing measurement left running");
    CSV csv(options.csv);
    std::string session;
    int code = 0;
    bool stopping = false;
    std::uint64_t expected = 1;
    const auto required = options.samples.value_or(static_cast<std::uint64_t>(std::ceil(options.duration.value_or(1) / options.gate)));
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::duration<double>(static_cast<double>(required) * options.gate + 2 * static_cast<double>(options.timeout) / 1000 + 10);
    auto stream = counter.stream();
    try {
        const auto accepted = counter.start(options.gate, options.duration);
        session = accepted.at("session_id").get<std::string>();
        if (session.empty()) throw c8855::APIError("Start returned no session ID");
        bool seen = false;
        while (true) {
            if (interrupted && !stopping) { stopOwn(counter, session, false); stopping = true; }
            if (std::chrono::steady_clock::now() > deadline) throw c8855::APIError("Recording timed out; partial CSV retained");
            const auto event = stream.next();
            if (event.at("type") == "heartbeat") continue;
            if (event.value("session_id", "") != session) {
                if (seen) throw c8855::APIError("Measurement session changed; partial CSV retained");
                continue; // The stream's initial status describes the preceding session.
            }
            seen = true;
            if (event.at("type") == "sample") {
                const auto sample = c8855::Sample::from_event(event);
                if (sample.sequence != expected) throw c8855::APIError("Missing or duplicate sample; partial CSV retained");
                if (sample.gate_seconds != options.gate) throw c8855::APIError("Gate changed; partial CSV retained");
                ++expected; csv.sample(event, sample);
                if (options.samples && csv.rows >= *options.samples && !stopping) { stopOwn(counter, session, false); stopping = true; }
            } else if (event.at("type") == "status" && !event.at("running").get<bool>()) {
                if (!event.at("error").get<std::string>().empty()) throw c8855::APIError(event.at("error").get<std::string>());
                if (!interrupted && csv.rows < required) { code = 3; std::cerr << "Recording ended before the requested samples; partial CSV retained\n"; }
                break;
            }
        }
    } catch (const Json::exception&) { code = 1; std::cerr << "Invalid API JSON or sample metadata; partial CSV retained\n"; }
      catch (const std::exception& error) { code = 1; std::cerr << redact(error.what()) << '\n'; }
    if (!session.empty()) {
        try { stopOwn(counter, session, true); }
        catch (const std::exception& error) { code = 1; std::cerr << redact(error.what()) << '\n'; }
    }
    csv.finish();
    if (interrupted && code == 0) code = 128 + interrupted;
    std::cerr << Json({{"recorded_samples", csv.rows}, {"requested_samples", required}, {"session_id", session},
                      {"complete", code == 0}, {"timing", "USB reception; not photon arrival or gate-start timing"}}).dump() << '\n';
    return code;
}
} // namespace

int main(int argc, char** argv) {
    if (argc == 2 && (std::string(argv[1]) == "--help" || std::string(argv[1]) == "help")) { help(); return 0; }
    try {
        const auto options = parse(argc, argv);
        const c8855::Client counter(static_cast<std::uint16_t>(options.port), options.timeout);
        if (options.command == "record") {
            std::signal(SIGINT, interrupt); std::signal(SIGTERM, interrupt);
            return record(options, counter);
        }
        Json state;
        if (options.command == "status") state = counter.status();
        else if (options.command == "settings") {
            state = {{"gate_seconds_supported", {0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1}},
                     {"duration_seconds_min", 1}, {"duration_seconds_max", 3600},
                     {"usb_batch_seconds_for_short_gates", 0.1}, {"state", counter.status()}};
        } else if (options.command == "start") state = counter.start(options.gate, options.duration);
        else state = counter.stop(); // Explicit stop command, never implied by a read-only command.
        std::cout << safeJSON(state).dump() << '\n';
        return 0;
    } catch (const Json::exception&) { std::cerr << "Invalid API JSON or metadata\n"; }
      catch (const std::exception& error) { std::cerr << redact(error.what()) << '\n'; }
    return 1;
}
