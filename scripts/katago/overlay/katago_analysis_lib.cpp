/**
 * In-process C API for KataGo analysis (iOS / library embedding).
 * No subprocess or executable spawning; complies with Apple App Store.
 */
#include "main.h"
#include "core/global.h"
#include "external/nlohmann_json/json.hpp"
#include <thread>
#include <mutex>
#include <condition_variable>
#include <queue>
#include <map>
#include <string>
#include <cstring>
#include <cstdlib>
#include <chrono>

extern "C" {

struct kg_analysis_handle {
  std::thread worker;
  std::mutex req_mutex;
  std::condition_variable req_cv;
  std::queue<std::string> request_queue;
  std::mutex rsp_mutex;
  std::condition_variable rsp_cv;
  std::map<std::string, std::string> response_by_id;
  bool done;
  bool stopped;
};

static void analysis_thread(kg_analysis_handle* h, std::vector<std::string> args) {
  auto getLineFn = [h]() -> std::string {
    std::unique_lock<std::mutex> lock(h->req_mutex);
    h->req_cv.wait(lock, [h] { return !h->request_queue.empty() || h->stopped; });
    if (h->stopped || h->request_queue.empty())
      return std::string();
    std::string line = std::move(h->request_queue.front());
    h->request_queue.pop();
    return line;
  };
  auto writeLineFn = [h](const std::string& s) {
    std::string id;
    try {
      nlohmann::json j = nlohmann::json::parse(s);
      if (j.contains("warning") && !j.contains("rootInfo") && !j.contains("error"))
        return;
      if (j.contains("isDuringSearch") &&
          j["isDuringSearch"].is_boolean() &&
          j["isDuringSearch"].get<bool>())
        return;
      if (j.contains("id") && j["id"].is_string())
        id = j["id"].get<std::string>();
    } catch (...) {
    }
    std::lock_guard<std::mutex> lock(h->rsp_mutex);
    if (!id.empty())
      h->response_by_id[id] = s;
    h->rsp_cv.notify_all();
  };
  MainCmds::analysis(args, getLineFn, writeLineFn);
  {
    std::lock_guard<std::mutex> lock(h->rsp_mutex);
    h->done = true;
    h->rsp_cv.notify_all();
  }
}

kg_analysis_handle* kg_analysis_create(const char* config_path, const char* model_path) {
  if (!config_path || !model_path)
    return nullptr;
  kg_analysis_handle* h = new kg_analysis_handle();
  h->done = false;
  h->stopped = false;
  std::vector<std::string> args = {
    "analysis",
    "-config", config_path,
    "-model", model_path
  };
  h->worker = std::thread(analysis_thread, h, std::move(args));
  return h;
}

void kg_analysis_destroy(kg_analysis_handle* h) {
  if (!h) return;
  {
    std::lock_guard<std::mutex> lock(h->req_mutex);
    h->stopped = true;
    h->req_cv.notify_all();
  }
  if (h->worker.joinable())
    h->worker.join();
  delete h;
}

char* kg_analysis_analyze(kg_analysis_handle* h, const char* request_json) {
  if (!h || !request_json)
    return nullptr;
  std::string expected_id;
  try {
    nlohmann::json req = nlohmann::json::parse(request_json);
    if (req.contains("id") && req["id"].is_string())
      expected_id = req["id"].get<std::string>();
  } catch (...) {
  }
  {
    std::lock_guard<std::mutex> lock(h->req_mutex);
    h->request_queue.push(request_json);
    h->req_cv.notify_one();
  }
  constexpr int wait_seconds = 300;
  std::unique_lock<std::mutex> lock(h->rsp_mutex);
  auto has_our_response = [h, &expected_id] {
    if (h->done) return true;
    if (!expected_id.empty() && h->response_by_id.count(expected_id) > 0) return true;
    return expected_id.empty() && !h->response_by_id.empty();
  };
  bool got = h->rsp_cv.wait_for(lock, std::chrono::seconds(wait_seconds), has_our_response);
  (void)got;
  std::string out;
  if (!expected_id.empty() && h->response_by_id.count(expected_id) > 0) {
    out = std::move(h->response_by_id[expected_id]);
    h->response_by_id.erase(expected_id);
  } else if (!h->response_by_id.empty()) {
    out = std::move(h->response_by_id.begin()->second);
    h->response_by_id.erase(h->response_by_id.begin());
  }
  if (out.empty())
    return nullptr;
  char* buf = static_cast<char*>(malloc(out.size() + 1));
  if (!buf) return nullptr;
  memcpy(buf, out.c_str(), out.size() + 1);
  return buf;
}

void kg_analysis_free_string(char* s) {
  free(s);
}

} // extern "C"
