#pragma once

#include <string>
#include <vector>

#ifdef LIBSTF_WITH_PROFILING
#include <caliper/cali-manager.h>
#include <caliper/cali.h>
#endif

namespace libstf {
class profiler {
#ifdef LIBSTF_WITH_PROFILING
private:
  static cali::ConfigManager mgr;
#endif

public:
  static void init();

  static void start();

  static void flush();

  // opens the regions for profiling in the same order as the regions vector
  static void open_regions(const std::vector<std::string> &regions);

  // closes the regions for profiling in the reverse order as the regions
  // vector
  static void close_regions(const std::vector<std::string> &regions);
};

} // namespace libstf
