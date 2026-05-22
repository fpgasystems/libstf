#include <getopt.h>

#include <libstf/common.hpp>
#include <libstf/memory_pool.hpp>
#include <libstf/output_buffer_manager.hpp>
#include <libstf/output_handle.hpp>
#include <libstf/tlb_manager.hpp>
#include <libstf/util.hpp>

using namespace libstf;

struct Args {
    bool   huge_pages           = true;
    size_t num_enqueued_buffers = 2;
    size_t buffer_size          = MAXIMUM_OUTPUT_WRITER_BUFFER_SIZE;
    size_t num_streams          = 1;
    size_t size                 = 512 * 1024 * 1024;
    size_t num_runs             = 8;
};

void print_usage(const char *prog) {
    std::cerr << "Usage: " << prog << " [OPTIONS]\n"
              << "\n"
              << "LibSTF output buffer manager example.\n"
              << "\n"
              << "Options:\n"
              << "  -p, --smallpages        Disable huge pages (for simulation)\n"
              << "  -e, --enqueued N        Number of output buffers to enqueue (default: 2)\n"
              << "  -b, --buffer-size BYTES Output buffer capacity (default: 256MiB - 64KiB)\n"
              << "  -S, --streams N         Number of streams (default: 1)\n"
              << "  -s, --size BYTES        Input size (default: 512MiB)\n"
              << "  -r, --runs N            Number of runs (default: 8)\n"
              << "  -h, --help              Show this help message\n";
}

Args parse_args(int argc, char *argv[]) {
    Args args;

    static struct option long_options[] = {{"smallpages", no_argument, 0, 'p'},
                                           {"enqueued", required_argument, 0, 'e'},
                                           {"buffer-size", required_argument, 0, 'b'},
                                           {"streams", required_argument, 0, 'S'},
                                           {"size", required_argument, 0, 's'},
                                           {"runs", required_argument, 0, 'r'},
                                           {0, 0, 0, 0}};

    int opt;
    while ((opt = getopt_long(argc, argv, "pe:b:S:s:r:h", long_options, nullptr)) != -1) {
        switch (opt) {
        case 'p':
            args.huge_pages = false;
            break;
        case 'e':
            args.num_enqueued_buffers = std::stoi(optarg);
            break;
        case 'b':
            args.buffer_size = std::stoi(optarg);
            break;
        case 'S':
            args.num_streams = std::stoi(optarg);
            break;
        case 's':
            args.size = std::stoi(optarg);
            break;
        case 'r':
            args.num_runs = std::stoi(optarg);
            break;
        case 'h':
            print_usage(argv[0]);
            exit(0);
        default:
            print_usage(argv[0]);
            exit(1);
        }
    }

    return args;
}

int main(int argc, char *argv[]) {
    Args args = parse_args(argc, argv);

    HEADER("CLI PARAMETERS:");
    std::cout << "Enable hugepages: " << args.huge_pages << std::endl;
    std::cout << "Number of buffers to enqueue: " << args.num_enqueued_buffers << std::endl;
    std::cout << "Output buffer size: " << args.buffer_size << std::endl;
    std::cout << "Number of streams: " << args.num_streams << std::endl;
    std::cout << "Input size: " << args.size << std::endl;
    std::cout << "Number of runs: " << args.num_runs << std::endl;

    // Obtain memory pool
    std::shared_ptr<libstf::MemoryPool> mem_pool;
    if (args.huge_pages) {
        mem_pool = std::make_shared<libstf::HugePageMemoryPool>();
    } else {
        mem_pool = std::make_shared<libstf::SimpleMemoryPool>();
    }

    // Initialize environment
    OutputBufferManager *obm_ptr = nullptr;
    auto cthread = std::make_shared<coyote::cThread>(0, getpid(), 0, [&obm_ptr](int value) {
        if (obm_ptr)
            (*obm_ptr).handle_fpga_interrupt(value);
    });

    GlobalConfig global_config(cthread);
    auto         tlb_manager = std::make_shared<libstf::TLBManager>(cthread, mem_pool);
    auto         mem_config  = global_config.get_config<libstf::MemConfig>();
    auto         perf_config = global_config.get_config<libstf::Config>();

    OutputBufferManager output_buffer_manager(cthread, mem_config, mem_pool, tlb_manager,
                                              ~stream_mask_t(0), args.num_enqueued_buffers, 
                                              args.buffer_size);
    obm_ptr = &output_buffer_manager;

    perf_config->write_register(ConfigRegister(0, args.num_runs));

    assert(global_config.system_id() == 0);
    assert(args.num_streams > 0 && args.num_streams <= mem_config->num_streams());

    // Pre-map huge pages to FPGA TLB
    auto *huge_pool = dynamic_cast<libstf::HugePageMemoryPool *>(mem_pool.get());
    if (huge_pool) { // If this is a HugePageMemoryPool pre-map all pages
        tlb_manager->ensure_tlb_mapping(huge_pool->initial_address(), huge_pool->total_capacity());
    }

    // Flush stale buffers from system
    output_buffer_manager.flush_buffers();

    // Initialize input
    std::cout << std::endl << "Generating input data..." << std::endl;

    uint8_t *input;
    auto     status = mem_pool->allocate(args.size, (void **)&input);
    if (!status.ok()) {
        std::cout << "[FATAL]: Could not allocate input buffer" << std::endl;
        return EXIT_FAILURE;
    }

    for (size_t i = 0; i < args.size / sizeof(uint64_t); i++) {
        ((uint64_t *)input)[i] = i;
    }

    // Benchmark
    std::cout << "Starting execution..." << std::endl;
    auto start = std::chrono::high_resolution_clock::now();

    stream_mask_t                              mask_all((1 << args.num_streams) - 1);
    std::vector<std::shared_ptr<OutputHandle>> handles;
    for (size_t i = 0; i < args.num_runs; i++) {
        handles.emplace_back(output_buffer_manager.acquire_output_handle(mask_all));
    }

    std::vector<std::vector<std::shared_ptr<Buffer>>> output(args.num_runs);
    std::thread                                       result_fetcher([&args, &handles, &output]() {
        for (size_t i = 0; i < args.num_runs; i++) {
            while (handles[i]->any_stream_has_more_output()) {
                for (size_t j = 0; j < args.num_streams; j++) {
                    output[i].emplace_back(handles[i]->get_next_stream_output(j));
                }
            }
        }
    });

    for (size_t i = 0; i < args.num_runs; i++) {
        for (size_t j = 0; j < args.num_streams; j++) {
            enqueue_stream_input(cthread, tlb_manager, input, args.size, j, true);
        }
    }

    result_fetcher.join();
    auto end = std::chrono::high_resolution_clock::now();
    auto us  = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

    // Verify result
    std::cout << "Verifying output data..." << std::endl;

    size_t num_wrong_values = 0;
    for (size_t s = 0; s < args.num_streams; s++) {
        auto  &stream_output = output[s];
        size_t i             = 0;
        for (auto buffer : stream_output) {
            auto ptr = (uint64_t *)buffer->ptr;
            for (size_t j = 0; j < buffer->size / sizeof(uint64_t); j++) {
                if (ptr[j] != i++) {
                    if (num_wrong_values == 0) {
                        HEADER("VERIFICATION FAILED:");
                    }
                    if (num_wrong_values < 5) {
                        std::cout << "[ASSERT] Result[" << s << "]: " << ptr[j] << " != " << i
                                  << std::endl;
                    }
                    if (num_wrong_values == 5) {
                        std::cout << "..." << std::endl;
                    }
                    num_wrong_values++;
                }
            }
        }
        assert(i == args.size / sizeof(uint64_t));
    }

    // Print results
    size_t handshake_cycles = 0;
    size_t starved_cycles   = 0;
    size_t stalled_cycles   = 0;
    size_t idle_cycles      = 0;
    for (size_t i = 0; i < args.num_streams; i++) {
        handshake_cycles += perf_config->read_register(4 * i + 1).value();
        starved_cycles += perf_config->read_register(4 * i + 2).value();
        stalled_cycles += perf_config->read_register(4 * i + 3).value();
        idle_cycles += perf_config->read_register(4 * i + 4).value();
    }

    auto total_cycles   = handshake_cycles + starved_cycles + stalled_cycles + idle_cycles;
    auto device_runtime = ((double)total_cycles) / 250.0;

    HEADER("RESULTS:");
    std::cout << "Host runtime: " << us << "us" << std::endl;
    std::cout << "Host throughput: " << (double)(args.size * args.num_runs) / us << "MB/s"
              << std::endl
              << std::endl;
    std::cout << "Handshake cycles: " << handshake_cycles << " ("
              << ((double)handshake_cycles) / total_cycles * 100 << "%)" << std::endl;
    std::cout << "Starved cycles: " << starved_cycles << " ("
              << ((double)starved_cycles) / total_cycles * 100 << "%)" << std::endl;
    std::cout << "Stalled cycles: " << stalled_cycles << " ("
              << ((double)stalled_cycles) / total_cycles * 100 << "%)" << std::endl;
    std::cout << "Idle cycles: " << idle_cycles << " ("
              << ((double)idle_cycles) / total_cycles * 100 << "%)" << std::endl;
    std::cout << "Total cycles: " << total_cycles << std::endl;
    std::cout << "Device throughput: " << (double)(args.size * args.num_runs) / device_runtime
              << "MB/s" << std::endl;

    return EXIT_SUCCESS;
}
