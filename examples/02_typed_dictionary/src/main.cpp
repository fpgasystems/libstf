#include <getopt.h>

#include <algorithm>
#include <chrono>
#include <numeric>
#include <random>
#include <vector>

#include <libstf/common.hpp>
#include <libstf/configuration.hpp>
#include <libstf/memory_pool.hpp>
#include <libstf/tlb_manager.hpp>
#include <libstf/util.hpp>

using namespace libstf;

// Must match the parameters of hardware/unit-tests/vfpga_tops/typed_dict_test.sv. The dictionary
// id width (dict_id_t) bounds the capacity to 2**DICT_ID_BITS 32-bit slots
static constexpr size_t DICT_ID_BITS = 18;
static constexpr size_t NUM_BANKS    = 16;
static constexpr size_t IDS_PER_BEAT = 16;

struct Args {
    size_t value_bits = 32;
    size_t num_values = 1 << 17;
    size_t num_ids    = 16 * 1024 * 1024;
    double zipf       = 0.0;
    size_t num_runs   = 5;
    size_t seed       = 42;
    bool   distinct   = false;
};

void print_usage(const char *prog) {
    std::cerr << "Usage: " << prog << " [OPTIONS]\n"
              << "\n"
              << "LibSTF typed dictionary benchmark. Builds a dictionary of --values entries on the\n"
              << "FPGA and materializes --ids randomly drawn ids through it.\n"
              << "\n"
              << "Options:\n"
              << "  -t, --type BITS    Value type width: 32 or 64 (default: 32)\n"
              << "  -v, --values N     Number of dictionary entries (default: 131072)\n"
              << "  -i, --ids N        Number of ids to materialize (default: 16Mi)\n"
              << "  -z, --zipf THETA   Zipf skew of the id distribution, 0 = uniform (default: 0)\n"
              << "  -d, --distinct     Keep each id's bank but make the ids themselves distinct, so\n"
              << "                     the within-beat deduplication cannot collapse repeated ids\n"
              << "  -r, --runs N       Number of runs (default: 5)\n"
              << "  -s, --seed N       Random seed (default: 42)\n"
              << "  -h, --help         Show this help message\n";
}

Args parse_args(int argc, char *argv[]) {
    Args args;

    static struct option long_options[] = {{"type", required_argument, 0, 't'},
                                           {"values", required_argument, 0, 'v'},
                                           {"ids", required_argument, 0, 'i'},
                                           {"zipf", required_argument, 0, 'z'},
                                           {"distinct", no_argument, 0, 'd'},
                                           {"runs", required_argument, 0, 'r'},
                                           {"seed", required_argument, 0, 's'},
                                           {0, 0, 0, 0}};

    int opt;
    while ((opt = getopt_long(argc, argv, "t:v:i:z:dr:s:h", long_options, nullptr)) != -1) {
        switch (opt) {
        case 't':
            args.value_bits = std::stoul(optarg);
            break;
        case 'v':
            args.num_values = std::stoul(optarg);
            break;
        case 'i':
            args.num_ids = std::stoul(optarg);
            break;
        case 'z':
            args.zipf = std::stod(optarg);
            break;
        case 'd':
            args.distinct = true;
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

    if (args.value_bits != 32 && args.value_bits != 64) {
        std::cerr << "[FATAL]: --type must be 32 or 64" << std::endl;
        exit(1);
    }

    // 64-bit values occupy two 32-bit dictionary slots
    size_t capacity = 1UL << (args.value_bits == 32 ? DICT_ID_BITS : DICT_ID_BITS - 1);
    if (args.num_values == 0 || args.num_values > capacity) {
        std::cerr << "[FATAL]: --values must be in [1, " << capacity << "] for " << args.value_bits
                  << "-bit values" << std::endl;
        exit(1);
    }

    if (args.distinct && args.num_values < NUM_BANKS) {
        std::cerr << "[FATAL]: --distinct needs at least " << NUM_BANKS << " dictionary entries"
                  << std::endl;
        exit(1);
    }

    // The ids arrive 16 per databeat; a full multiple keeps the output at whole databeats too
    args.num_ids = (args.num_ids + IDS_PER_BEAT - 1) / IDS_PER_BEAT * IDS_PER_BEAT;

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
 * Draws num_ids ids from [0, num_values). With theta == 0 the distribution is uniform; otherwise
 * ids are drawn from a Zipf distribution with skew theta whose ranks are scattered over the id
 * space by a random permutation, so the hot ids do not cluster in a single dictionary bank.
 *
 * With distinct set, each drawn id keeps its dictionary bank (id % NUM_BANKS) but its slot within
 * the bank is replaced by a rotating per-bank counter. The bank load distribution of the skew is
 * preserved, but repeated hits to a hot bank are distinct ids, so the within-beat deduplication in
 * hardware cannot collapse them and the lookups fully serialize on the bank.
 */
std::vector<uint32_t> generate_ids(const Args &args) {
    std::mt19937_64       rng(args.seed);
    std::vector<uint32_t> ids(args.num_ids);

    if (args.zipf == 0.0) {
        std::uniform_int_distribution<uint32_t> dist(0, args.num_values - 1);
        for (auto &id : ids) {
            id = dist(rng);
        }
    } else {
        // Zipf CDF over the ranks: weight of rank r is 1 / (r + 1)^theta
        std::vector<double> cdf(args.num_values);
        double              sum = 0.0;
        for (size_t r = 0; r < args.num_values; r++) {
            sum += 1.0 / std::pow((double)(r + 1), args.zipf);
            cdf[r] = sum;
        }

        // Scatter the ranks over the id space
        std::vector<uint32_t> rank_to_id(args.num_values);
        std::iota(rank_to_id.begin(), rank_to_id.end(), 0);
        std::shuffle(rank_to_id.begin(), rank_to_id.end(), rng);

        std::uniform_real_distribution<double> dist(0.0, sum);
        for (auto &id : ids) {
            auto rank = std::upper_bound(cdf.begin(), cdf.end(), dist(rng)) - cdf.begin();
            id        = rank_to_id[rank];
        }
    }

    if (args.distinct) {
        size_t                slots_per_bank = args.num_values / NUM_BANKS;
        std::vector<uint32_t> next_slot(NUM_BANKS, 0);
        for (auto &id : ids) {
            uint32_t bank = id % NUM_BANKS;
            id            = next_slot[bank] * NUM_BANKS + bank;
            next_slot[bank] = (next_slot[bank] + 1) % slots_per_bank;
        }
    }

    return ids;
}

void print_id_distribution_stats(const Args &args, const std::vector<uint32_t> &ids) {
    std::vector<size_t> bank_counts(NUM_BANKS, 0);
    for (auto id : ids) {
        bank_counts[id % NUM_BANKS]++;
    }

    std::cout << "Hottest bank share: "
              << (double)*std::max_element(bank_counts.begin(), bank_counts.end()) / args.num_ids *
                     100
              << "% (balanced: " << 100.0 / NUM_BANKS << "%)" << std::endl;
}

template <typename value_t> void fill_values(void *values, size_t num_values) {
    // Values are a mix of the index so addressing bugs are caught during verification
    for (size_t i = 0; i < num_values; i++) {
        ((value_t *)values)[i] = (value_t)(i * 0x9E3779B97F4A7C15ULL + 1);
    }
}

template <typename value_t>
size_t verify_output(const void *values, const std::vector<uint32_t> &ids, const void *output) {
    size_t num_wrong_values = 0;
    for (size_t i = 0; i < ids.size(); i++) {
        auto expected = ((const value_t *)values)[ids[i]];
        auto actual   = ((const value_t *)output)[i];
        if (actual != expected) {
            if (num_wrong_values == 0) {
                HEADER("VERIFICATION FAILED:");
            }
            if (num_wrong_values < 5) {
                std::cout << "[ASSERT] Result[" << i << "]: " << actual << " != " << expected
                          << std::endl;
            }
            if (num_wrong_values == 5) {
                std::cout << "..." << std::endl;
            }
            num_wrong_values++;
        }
    }
    return num_wrong_values;
}

int main(int argc, char *argv[]) {
    Args args = parse_args(argc, argv);

    size_t value_bytes  = args.value_bits / 8;
    size_t values_size  = args.num_values * value_bytes;
    size_t ids_size     = args.num_ids * sizeof(uint32_t);
    size_t output_size  = args.num_ids * value_bytes;
    type_t value_type   = args.value_bits == 32 ? type_t::INT32_T : type_t::INT64_T;

    HEADER("CLI PARAMETERS:");
    std::cout << "Value type: " << args.value_bits << "-bit" << std::endl;
    std::cout << "Number of dictionary entries: " << args.num_values << std::endl;
    std::cout << "Number of ids: " << args.num_ids << std::endl;
    std::cout << "Zipf skew: " << args.zipf << std::endl;
    std::cout << "Distinct ids: " << args.distinct << std::endl;
    std::cout << "Number of runs: " << args.num_runs << std::endl;
    std::cout << "Seed: " << args.seed << std::endl;

    // Obtain memory pool
    std::shared_ptr<libstf::MemoryPool> mem_pool;
#ifdef EN_SIMULATION
    mem_pool = std::make_shared<libstf::SimpleMemoryPool>();
#else
    mem_pool = std::make_shared<libstf::HugePageMemoryPool>();
#endif

    // Initialize environment
    auto cthread     = std::make_shared<coyote::cThread>(0, getpid());
    auto tlb_manager = std::make_shared<libstf::TLBManager>(cthread, mem_pool);

    GlobalConfig global_config(cthread);
    assert(global_config.system_id() == 0);

    auto stream_config = global_config.get_config<libstf::StreamConfig>();
    assert(stream_config->num_streams() == 1);

    // Pre-map huge pages to FPGA TLB
    auto *huge_pool = dynamic_cast<libstf::HugePageMemoryPool *>(mem_pool.get());
    if (huge_pool) {
        tlb_manager->ensure_tlb_mapping(huge_pool->initial_address(), huge_pool->total_capacity());
    }

    // Initialize input
    std::cout << std::endl << "Generating input data..." << std::endl;

    void *values, *ids_buffer, *output;
    if (!mem_pool->allocate(values_size, &values).ok() ||
        !mem_pool->allocate(ids_size, &ids_buffer).ok() ||
        !mem_pool->allocate(output_size, &output).ok()) {
        std::cout << "[FATAL]: Could not allocate buffers" << std::endl;
        return EXIT_FAILURE;
    }

    if (args.value_bits == 32) {
        fill_values<uint32_t>(values, args.num_values);
    } else {
        fill_values<uint64_t>(values, args.num_values);
    }

    auto ids = generate_ids(args);
    std::copy(ids.begin(), ids.end(), (uint32_t *)ids_buffer);
    print_id_distribution_stats(args, ids);

    // Benchmark
    std::cout << std::endl << "Starting execution..." << std::endl;

    size_t num_wrong_values = 0;
    double total_us         = 0.0;
    for (size_t run = 0; run < args.num_runs; run++) {
        std::memset(output, 0, output_size);
        cthread->clearCompleted();

        // One stream config is consumed per values stream
        stream_config->enqueue_stream_config(0, value_type, 0);

        auto start = std::chrono::high_resolution_clock::now();

        auto num_output_transfers =
            enqueue_stream_output(cthread, tlb_manager, output, output_size, 0);
        enqueue_stream_input(cthread, tlb_manager, values, values_size, 0, true);
        enqueue_stream_input(cthread, tlb_manager, ids_buffer, ids_size, 1, true);

        while (cthread->checkCompleted(coyote::CoyoteOper::LOCAL_WRITE) != num_output_transfers) {}

        auto end = std::chrono::high_resolution_clock::now();
        auto us  = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();
        total_us += us;

        std::cout << "Run " << run << ": " << us << "us" << std::endl;

        if (args.value_bits == 32) {
            num_wrong_values += verify_output<uint32_t>(values, ids, output);
        } else {
            num_wrong_values += verify_output<uint64_t>(values, ids, output);
        }
    }

    // Print results
    auto avg_us = total_us / args.num_runs;

    HEADER("RESULTS:");
    std::cout << "Wrong output values: " << num_wrong_values << std::endl;
    std::cout << "Average runtime: " << avg_us << "us" << std::endl;
    std::cout << "Materialization rate: " << (double)args.num_ids / avg_us << " Mids/s"
              << std::endl;
    std::cout << "Output throughput: " << (double)output_size / avg_us << "MB/s" << std::endl;

    return num_wrong_values == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
