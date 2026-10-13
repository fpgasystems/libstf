#include <getopt.h>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <random>
#include <vector>

#include <libstf/common.hpp>
#include <libstf/configuration.hpp>
#include <libstf/memory_pool.hpp>
#include <libstf/tlb_manager.hpp>
#include <libstf/util.hpp>

using namespace libstf;

// Clock frequency of the vFPGA in MHz, which the stream profiles count cycles of
static constexpr double CLOCK_MHZ = 250.0;
// The ring buffer gets its own 1 GiB huge pages so offloading it to the card does not move any of
// the host buffers
static constexpr size_t RING_BUFFER_ALIGNMENT = 1ULL << 30;

struct Args {
    size_t stream_bytes = 16 * 1024 * 1024;
    size_t num_streams  = 4;
    size_t num_reads    = 3;
    size_t ring_bytes   = 1ULL << 30;
    size_t num_runs     = 3;
    size_t seed         = 42;
};

void print_usage(const char *prog) {
    std::cerr << "Usage: " << prog << " [OPTIONS]\n"
              << "\n"
              << "LibSTF replay buffer example. Streams --streams streams of --bytes bytes to the\n"
              << "FPGA, which stores them in a ring buffer in card memory and sends each of them\n"
              << "back --reads times.\n"
              << "\n"
              << "Options:\n"
              << "  -b, --bytes N      Bytes per stream, a multiple of 8 (default: 16Mi)\n"
              << "  -n, --streams N    Number of streams per run, at most the number of streams\n"
              << "                     the replay buffer can enqueue (default: 4)\n"
              << "  -k, --reads N      How often each stream is read (default: 3)\n"
              << "  -m, --ring N       Size of the ring buffer in card memory in bytes (default: 1Gi)\n"
              << "  -r, --runs N       Number of runs (default: 3)\n"
              << "  -s, --seed N       Random seed (default: 42)\n"
              << "  -h, --help         Show this help message\n";
}

Args parse_args(int argc, char *argv[]) {
    Args args;

    static struct option long_options[] = {{"bytes", required_argument, 0, 'b'},
                                           {"streams", required_argument, 0, 'n'},
                                           {"reads", required_argument, 0, 'k'},
                                           {"ring", required_argument, 0, 'm'},
                                           {"runs", required_argument, 0, 'r'},
                                           {"seed", required_argument, 0, 's'},
                                           {0, 0, 0, 0}};

    int opt;
    while ((opt = getopt_long(argc, argv, "b:n:k:m:r:s:h", long_options, nullptr)) != -1) {
        switch (opt) {
        case 'b':
            args.stream_bytes = std::stoul(optarg);
            break;
        case 'n':
            args.num_streams = std::stoul(optarg);
            break;
        case 'k':
            args.num_reads = std::stoul(optarg);
            break;
        case 'm':
            args.ring_bytes = std::stoul(optarg);
            break;
        case 'r':
            args.num_runs = std::stoul(optarg);
            break;
        case 's':
            args.seed = std::stoul(optarg);
            break;
        case 'h':
            print_usage(argv[0]);
            exit(0);
        default:
            print_usage(argv[0]);
            exit(1);
        }
    }

    if (args.stream_bytes == 0 || args.stream_bytes % sizeof(uint64_t) != 0) {
        std::cerr << "[FATAL]: --bytes must be a positive multiple of 8" << std::endl;
        exit(1);
    }

    if (args.num_streams == 0) {
        std::cerr << "[FATAL]: --streams must be at least 1" << std::endl;
        exit(1);
    }

    if (args.num_reads == 0) {
        std::cerr << "[FATAL]: --reads must be at least 1" << std::endl;
        exit(1);
    }

    if (args.ring_bytes % MEMORY_ALIGNMENT_BYTES != 0) {
        std::cerr << "[FATAL]: --ring must be a multiple of " << MEMORY_ALIGNMENT_BYTES << std::endl;
        exit(1);
    }

    return args;
}

/**
 * Counterpart to libstf::enqueue_stream_input: posts chunked LOCAL_WRITE transfers that receive a
 * stream from the FPGA into the given buffer. Returns the number of transfers posted.
 */
size_t enqueue_stream_output(std::shared_ptr<coyote::cThread> cthread,
                             std::shared_ptr<TLBManager> tlb_manager, void *ptr, size_t size,
                             stream_t stream) {
    auto byte_ptr = static_cast<std::byte *>(ptr);

    tlb_manager->ensure_tlb_mapping(ptr, size);

    size_t num_transfers = 0;
    for (size_t off = 0; off < size; off += coyote::MAX_TRANSFER_SIZE) {
        coyote::localSg sg;
        sg.addr   = byte_ptr + off;
        sg.len    = std::min(size - off, coyote::MAX_TRANSFER_SIZE);
        sg.stream = coyote::STRM_HOST;
        sg.dest   = stream;

        cthread->invoke(coyote::CoyoteOper::LOCAL_WRITE, sg,
                        off + coyote::MAX_TRANSFER_SIZE >= size);
        num_transfers++;
    }

    return num_transfers;
}

/**
 * Moves the given memory to the card memory. Coyote always migrates whole mapped buffers, so we
 * off-load with a single call. Otherwise, every call would copy the whole buffer again.
 */
void offload_to_card(std::shared_ptr<coyote::cThread> cthread, void *ptr, size_t size) {
    coyote::syncSg sg;
    sg.addr = ptr;
    sg.len  = size;

    cthread->invoke(coyote::CoyoteOper::LOCAL_OFFLOAD, sg);
}

/**
 * Cycle counters of a stream profile in the vFPGA, see the StreamProfiler.
 */
struct StreamProfile {
    size_t handshake_cycles = 0;
    size_t starved_cycles   = 0;
    size_t stalled_cycles   = 0;
    size_t idle_cycles      = 0;
    size_t num_streams      = 0;

    size_t total_cycles() const {
        return handshake_cycles + starved_cycles + stalled_cycles + idle_cycles;
    }

    void operator+=(const StreamProfile &other) {
        handshake_cycles += other.handshake_cycles;
        starved_cycles += other.starved_cycles;
        stalled_cycles += other.stalled_cycles;
        idle_cycles += other.idle_cycles;
        num_streams += other.num_streams;
    }
};

// The GenericConfig holds the profile of the buffer input at index 0 and of its output at index 1
StreamProfile read_profile(std::shared_ptr<libstf::Config> profile_config, size_t index) {
    // Register 0 contains the ID of the configuration
    auto read = [&](size_t counter) {
        return profile_config->read_register(1 + 5 * index + counter).value();
    };

    StreamProfile profile;
    profile.handshake_cycles = read(0);
    profile.starved_cycles   = read(1);
    profile.stalled_cycles   = read(2);
    profile.idle_cycles      = read(3);
    profile.num_streams      = read(4);
    return profile;
}

void print_profile(const char *name, const StreamProfile &profile, double bytes) {
    auto total = profile.total_cycles();
    auto us    = total / CLOCK_MHZ;

    std::cout << name << ":" << std::endl;
    std::cout << "  Handshake cycles: " << profile.handshake_cycles << " ("
              << (double)profile.handshake_cycles / total * 100 << "%)" << std::endl;
    std::cout << "  Starved cycles: " << profile.starved_cycles << " ("
              << (double)profile.starved_cycles / total * 100 << "%)" << std::endl;
    std::cout << "  Stalled cycles: " << profile.stalled_cycles << " ("
              << (double)profile.stalled_cycles / total * 100 << "%)" << std::endl;
    std::cout << "  Idle cycles: " << profile.idle_cycles << " ("
              << (double)profile.idle_cycles / total * 100 << "%)" << std::endl;
    std::cout << "  Device throughput: " << bytes / us << "MB/s" << std::endl;
}

size_t verify_output(const void *input, const void *output, size_t size, size_t stream,
                     size_t read) {
    if (std::memcmp(input, output, size) == 0) {
        return 0;
    }

    size_t num_wrong_values = 0;
    for (size_t i = 0; i < size / sizeof(uint64_t); i++) {
        auto expected = ((const uint64_t *)input)[i];
        auto actual   = ((const uint64_t *)output)[i];
        if (actual != expected) {
            if (num_wrong_values < 5) {
                std::cout << "[ASSERT] Stream " << stream << ", read " << read << ", value " << i
                          << ": " << actual << " != " << expected << std::endl;
            }
            num_wrong_values++;
        }
    }
    return num_wrong_values;
}

int main(int argc, char *argv[]) {
    Args args = parse_args(argc, argv);

    HEADER("CLI PARAMETERS:");
    std::cout << "Bytes per stream: " << args.stream_bytes << std::endl;
    std::cout << "Number of streams: " << args.num_streams << std::endl;
    std::cout << "Reads per stream: " << args.num_reads << std::endl;
    std::cout << "Ring buffer size: " << args.ring_bytes << std::endl;
    std::cout << "Number of runs: " << args.num_runs << std::endl;
    std::cout << "Seed: " << args.seed << std::endl;

    // Obtain memory pool
    std::shared_ptr<libstf::MemoryPool> mem_pool;
    size_t                              ring_alignment;
#ifdef EN_SIMULATION
    mem_pool       = std::make_shared<libstf::SimpleMemoryPool>();
    ring_alignment = 64;
#else
    mem_pool       = std::make_shared<libstf::HugePageMemoryPool>();
    ring_alignment = RING_BUFFER_ALIGNMENT;
#endif

    // Initialize environment
    auto cthread     = std::make_shared<coyote::cThread>(0, getpid());
    auto tlb_manager = std::make_shared<libstf::TLBManager>(cthread, mem_pool);

    // The vFPGA accesses the memory with Coyote thread id 0
    if (cthread->getCtid() != 0) {
        std::cerr << "[FATAL]: Got Coyote thread id " << cthread->getCtid() << " instead of 0. Is "
                  << "another process using the vFPGA?" << std::endl;
        return EXIT_FAILURE;
    }

    GlobalConfig global_config(cthread);
    assert(global_config.system_id() == 0);

    auto replay_buffer_config = global_config.get_config<libstf::ReplayBufferConfig>();
    assert(replay_buffer_config->num_buffers() == 1);

    // The number of reads of all streams of a run is enqueued at once
    if (args.num_streams > replay_buffer_config->maximum_num_enqueued_streams()) {
        std::cerr << "[FATAL]: --streams must be at most "
                  << replay_buffer_config->maximum_num_enqueued_streams()
                  << ", the number of streams the replay buffer can enqueue" << std::endl;
        return EXIT_FAILURE;
    }

    // The replay buffer fills the ring buffer one transfer at a time. A stream that is read multiple
    // times is only released after its last read. So it has to fit into the ring buffer, together
    // with a transfer that might be skipped at the end of the ring buffer.
    size_t transfer_size    = replay_buffer_config->transfer_size();
    size_t stream_transfers = (args.stream_bytes + transfer_size - 1) / transfer_size;
    if (args.num_reads > 1 && (stream_transfers + 1) * transfer_size > args.ring_bytes) {
        std::cerr << "[FATAL]: A stream that is read multiple times has to fit into the ring "
                  << "buffer. Use --ring >= " << (stream_transfers + 1) * transfer_size << std::endl;
        return EXIT_FAILURE;
    }

    // The stream profiles stop after the streams of a run
    auto profile_config = global_config.get_config<libstf::Config>();
    profile_config->write_register(ConfigRegister(0, args.num_streams));
    profile_config->write_register(ConfigRegister(1, args.num_streams * args.num_reads));

    // Allocate the ring buffer first so it starts at a huge page and round it up to whole pages
    size_t ring_alloc_bytes = (args.ring_bytes + ring_alignment - 1) / ring_alignment * ring_alignment;
    void  *ring_buffer;
    if (!mem_pool->allocate(ring_alloc_bytes, ring_alignment, &ring_buffer).ok()) {
        std::cout << "[FATAL]: Could not allocate the ring buffer" << std::endl;
        return EXIT_FAILURE;
    }

    // Allocate the host buffers
    std::vector<void *> inputs(args.num_streams);
    std::vector<void *> outputs(args.num_streams * args.num_reads);
    for (auto &buffer : inputs) {
        if (!mem_pool->allocate(args.stream_bytes, &buffer).ok()) {
            std::cout << "[FATAL]: Could not allocate the input buffers" << std::endl;
            return EXIT_FAILURE;
        }
    }
    for (auto &buffer : outputs) {
        if (!mem_pool->allocate(args.stream_bytes, &buffer).ok()) {
            std::cout << "[FATAL]: Could not allocate the output buffers" << std::endl;
            return EXIT_FAILURE;
        }
    }

    // Pre-map huge pages to FPGA TLB
    auto *huge_pool = dynamic_cast<libstf::HugePageMemoryPool *>(mem_pool.get());
    if (huge_pool) {
        tlb_manager->ensure_tlb_mapping(huge_pool->initial_address(), huge_pool->total_capacity());
    }

    // Move the ring buffer to the card memory and configure the replay buffer with it
    std::cout << std::endl << "Offloading the ring buffer to card memory..." << std::endl;
    tlb_manager->ensure_tlb_mapping(ring_buffer, ring_alloc_bytes);
    offload_to_card(cthread, ring_buffer, ring_alloc_bytes);
    replay_buffer_config->configure_ring_buffer(0, reinterpret_cast<uint64_t>(ring_buffer),
                                                args.ring_bytes);

    // Initialize input
    std::cout << "Generating input data..." << std::endl;
    std::mt19937_64 rng(args.seed);
    for (auto buffer : inputs) {
        for (size_t i = 0; i < args.stream_bytes / sizeof(uint64_t); i++) {
            ((uint64_t *)buffer)[i] = rng();
        }
    }

    // The replay buffer writes every stream to the card memory with one write per transfer
    size_t num_card_writes = args.num_streams * stream_transfers;

    // Benchmark
    std::cout << std::endl << "Starting execution..." << std::endl;

    size_t        num_wrong_values = 0;
    double        total_us         = 0.0;
    StreamProfile input_profile, output_profile;
    for (size_t run = 0; run < args.num_runs; run++) {
        for (auto buffer : outputs) {
            std::memset(buffer, 0, args.stream_bytes);
        }
        cthread->clearCompleted();

        // One number of reads is consumed per stream
        for (size_t stream = 0; stream < args.num_streams; stream++) {
            replay_buffer_config->enqueue_num_reads(0, args.num_reads);
        }

        auto start = std::chrono::high_resolution_clock::now();

        // The replay buffer sends all reads of a stream before the next stream
        size_t num_output_transfers = 0;
        for (auto buffer : outputs) {
            num_output_transfers +=
                enqueue_stream_output(cthread, tlb_manager, buffer, args.stream_bytes, 0);
        }
        for (auto buffer : inputs) {
            enqueue_stream_input(cthread, tlb_manager, buffer, args.stream_bytes, 0, true);
        }

        // Coyote counts the completed writes per process id, independent of who issued them. The
        // replay buffer writes to the card memory with process id 0, so its writes count as well.
        while (cthread->checkCompleted(coyote::CoyoteOper::LOCAL_WRITE) !=
               num_output_transfers + num_card_writes) {}

        auto end = std::chrono::high_resolution_clock::now();
        auto us  = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();
        total_us += us;

        std::cout << "Run " << run << ": " << us << "us" << std::endl;

        input_profile += read_profile(profile_config, 0);
        output_profile += read_profile(profile_config, 1);

        for (size_t stream = 0; stream < args.num_streams; stream++) {
            for (size_t read = 0; read < args.num_reads; read++) {
                num_wrong_values +=
                    verify_output(inputs[stream], outputs[stream * args.num_reads + read],
                                  args.stream_bytes, stream, read);
            }
        }
    }

    // Print results
    auto avg_us       = total_us / args.num_runs;
    auto input_bytes  = (double)args.num_streams * args.stream_bytes;
    auto output_bytes = input_bytes * args.num_reads;

    HEADER("RESULTS:");
    std::cout << "Wrong output values: " << num_wrong_values << std::endl;
    std::cout << "Average host runtime: " << avg_us << "us" << std::endl;
    std::cout << "Host input throughput: " << input_bytes / avg_us << "MB/s" << std::endl;
    std::cout << "Host output throughput: " << output_bytes / avg_us << "MB/s" << std::endl;

    if (input_profile.num_streams != args.num_streams * args.num_runs ||
        output_profile.num_streams != args.num_streams * args.num_reads * args.num_runs) {
        std::cout << "[ASSERT] The stream profiles counted " << input_profile.num_streams
                  << " input and " << output_profile.num_streams << " output streams" << std::endl;
        num_wrong_values++;
    }

    std::cout << std::endl;
    print_profile("Buffer input", input_profile, input_bytes * args.num_runs);
    print_profile("Buffer output", output_profile, output_bytes * args.num_runs);

    return num_wrong_values == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
