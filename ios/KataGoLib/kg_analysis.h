/**
 * In-process KataGo analysis C API (iOS / App Store compliant).
 * No executables or subprocesses.
 */
#ifndef KG_ANALYSIS_H
#define KG_ANALYSIS_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct kg_analysis_handle kg_analysis_handle;

/** Create engine; config_path and model_path are UTF-8 file paths. */
kg_analysis_handle* kg_analysis_create(const char* config_path, const char* model_path);

/** Run one analysis request (JSON in), returns JSON out; caller must free with kg_analysis_free_string. */
char* kg_analysis_analyze(kg_analysis_handle* h, const char* request_json);

/** Free string returned by kg_analysis_analyze. */
void kg_analysis_free_string(char* s);

/** Destroy engine and join thread. */
void kg_analysis_destroy(kg_analysis_handle* h);

#ifdef __cplusplus
}
#endif

#endif
