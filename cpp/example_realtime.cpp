#include "c8855_client.hpp"
#include <csignal>
#include <iomanip>
#include <iostream>
#include <optional>
#include <string>

namespace { volatile std::sig_atomic_t interrupted = 0; void interrupt(int) { interrupted = 1; } }
int main(int argc, char** argv) {
    double gate = 0.1;
    std::optional<double> duration = 10;
    unsigned port = 8855;
    bool json_output = false, status_only = false, stop_only = false;
    std::string session;
    int result = 0;
    try {
        for (int i = 1; i < argc; ++i) {
            const std::string argument = argv[i];
            if (argument == "--json") json_output = true;
            else if (argument == "--status") status_only = true;
            else if (argument == "--stop") stop_only = true;
            else if (argument == "--continuous") duration.reset();
            else if (argument == "--help") {
                std::cout << "c8855_realtime [--gate 0.1] [--seconds 10 | --continuous] [--json] [--port 8855] [--status | --stop]\n";
                return 0;
            } else if (i + 1 < argc && argument == "--gate") gate = std::stod(argv[++i]);
            else if (i + 1 < argc && argument == "--seconds") duration = std::stod(argv[++i]);
            else if (i + 1 < argc && argument == "--port") {
                const long value = std::stol(argv[++i]);
                if (value < 1 || value > 65535) throw c8855::APIError("Invalid port");
                port = static_cast<unsigned>(value);
            } else throw c8855::APIError("Unknown or incomplete argument: " + argument);
        }
        c8855::Client counter(static_cast<std::uint16_t>(port));
        if (status_only) { std::cout << counter.status().dump() << '\n'; return 0; }
        if (stop_only) { std::cout << counter.stop().dump() << '\n'; return 0; }
        std::signal(SIGINT, interrupt);
        try {
            auto stream = counter.stream(); // Subscribe before starting; USB remains owned by app.
            session = counter.start(gate, duration).at("session_id").get<std::string>();
            std::uint64_t expected = 1;
            bool seen_session = false;
            bool stop_requested = false;
            while (true) {
                if (interrupted && !stop_requested) { counter.stop(false); stop_requested = true; }
                const auto event = stream.next();
                if (event.at("type") == "heartbeat") continue;
                if (event.value("session_id", "") != session) {
                    if (seen_session) throw c8855::APIError("Measurement session changed");
                    continue;
                }
                seen_session = true;
                if (event.at("type") == "sample") {
                    const auto sample = c8855::Sample::from_event(event);
                    if (sample.sequence != expected++) throw c8855::APIError("Missing sample; check CSV recording");
                    // Feed sample.counts and sample.received_unix_seconds to gaze estimation here.
                    if (json_output) std::cout << event.dump() << '\n';
                    else std::cout << std::fixed << std::setprecision(3) << sample.received_unix_seconds
                                   << "  " << sample.counts << " counts  " << sample.counts_per_second << " counts/s\n";
                    std::cout.flush();
                } else if (event.at("type") == "status" && !event.at("running").get<bool>()) {
                    if (!event.at("error").get<std::string>().empty()) throw c8855::APIError(event.at("error").get<std::string>());
                    break;
                }
            }
        } catch (const std::exception& error) { std::cerr << error.what() << '\n'; result = 1; }
        if (!session.empty()) {
            try {
                if (counter.status().value("session_id", "") == session) counter.stop();
            } catch (const std::exception& error) { std::cerr << error.what() << '\n'; result = 1; }
        }
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
    return result;
}
