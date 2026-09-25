/**
 * Stub implementations of Version:: for the in-process analysis library.
 * The analysis lib excludes main.cpp, so we provide these symbols here.
 * Used only when BUILD_ANALYSIS_LIB=ON (e.g. iOS); NO_GIT_REVISION is always implied.
 */
#include "main.h"
#include <sstream>

static const char* GIT_REVISION = "<omitted>";

namespace Version {

std::string getKataGoVersion() {
  return "1.18.1";
}

std::string getKataGoVersionForHelp() {
  return "KataGo v1.18.1 (analysis lib)";
}

std::string getKataGoVersionFullInfo() {
  std::ostringstream out;
  out << getKataGoVersionForHelp() << "\n";
  out << "Git revision: " << GIT_REVISION << "\n";
  out << "Using Eigen(CPU) backend" << "\n";
  return out.str();
}

std::string getGitRevision() {
  return GIT_REVISION;
}

std::string getGitRevisionWithBackend() {
  return std::string(GIT_REVISION) + "-eigen";
}

}  // namespace Version
