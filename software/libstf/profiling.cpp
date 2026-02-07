#include <libstf/profiling.hpp>

#ifdef LIBSTF_WITH_PROFILING
#include <stdexcept>
#include <string>

const std::string profile =
    "runtime-report(calc.inclusive=true,output=stdout),event-trace";
#endif

namespace libstf {

#ifdef LIBSTF_WITH_PROFILING
cali::ConfigManager profiler::mgr;
#endif

void profiler::init() {
#ifdef LIBSTF_WITH_PROFILING
  cali_config_set("CALI_CALIPER_ATTRIBUTE_DEFAULT_SCOPE", "process");
  mgr = cali::ConfigManager();
  mgr.add(profile.c_str());

  if (mgr.error()) {
    throw std::runtime_error("error while initializing caliper: " +
                             mgr.error_msg());
  }
#endif
}

void profiler::start() {
#ifdef LIBSTF_WITH_PROFILING
  mgr.start();
#endif
}

void profiler::flush() {
#ifdef LIBSTF_WITH_PROFILING
  mgr.flush();
#endif
}

void profiler::open_regions(const std::vector<std::string> &regions) {
#ifdef LIBSTF_WITH_PROFILING
  for (const auto &region : regions) {
    CALI_MARK_BEGIN(region.c_str());
  }
#endif
}

void profiler::close_regions(const std::vector<std::string> &regions) {
#ifdef LIBSTF_WITH_PROFILING
  // iterate over regions in reverse order
  for (auto it = regions.rbegin(); it != regions.rend(); ++it) {
    CALI_MARK_END(it->c_str());
  }
#endif
}

} // namespace libstf
