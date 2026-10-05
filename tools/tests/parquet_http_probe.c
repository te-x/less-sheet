#define _POSIX_C_SOURCE 200809L
#include <lesssheet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000.0 + t.tv_nsec / 1000000.0;
}
static void pause_ms(long ms) {
  struct timespec t = {.tv_sec = ms / 1000, .tv_nsec = (ms % 1000) * 1000000};
  nanosleep(&t, NULL);
}
static double max_call_ms;
static int window(ls_doc *doc, uint64_t row, uint32_t rows, uint32_t columns,
                  int expect_error) {
  double deadline = now() + 10000;
  while (now() < deadline) {
    double start = now();
    ls_row_range r = ls_window_set_columns(doc, row, rows, 0, columns);
    double elapsed = now() - start;
    if (elapsed > max_call_ms)
      max_call_ms = elapsed;
    if (elapsed >= 200) {
      fprintf(stderr, "foreground window blocked %.1f ms\n", elapsed);
      return 0;
    }
    if (ls_document_status(doc) != LS_OK)
      return expect_error;
    if (r.row_count == rows)
      return !expect_error;
    pause_ms(1);
  }
  fprintf(stderr, "window timed out at row %llu\n", (unsigned long long)row);
  return 0;
}
static int id_equals(ls_doc *doc, uint64_t row) {
  char expected[32];
  int n = snprintf(expected, sizeof expected, "%llu", (unsigned long long)row);
  ls_str value = ls_cell(doc, row, 0);
  return value.len == (size_t)n && !memcmp(value.ptr, expected, value.len);
}
int main(int argc, char **argv) {
  if (argc < 3)
    return 2;
  const char *mode = argv[2];
  double start = now();
  ls_net_open_job *job = ls_open_url_start(argv[1], strlen(argv[1]), NULL);
  if (!job)
    return 3;
  if (!strcmp(mode, "cancel-open")) {
    pause_ms(100);
    double closing = now();
    ls_net_open_cancel(job);
    ls_net_open_release(job);
    printf("{\"cancel_ms\":%.3f}\n", now() - closing);
    return now() - closing >= 200;
  }
  ls_net_open_status status;
  double deadline = now() + 10000;
  do {
    status = ls_net_open_poll(job);
    if (status.state == LS_NET_OPEN_DONE || status.state == LS_NET_OPEN_FAILED)
      break;
    pause_ms(1);
  } while (now() < deadline);
  if (!strcmp(mode, "open-error")) {
    int failed = status.state != LS_NET_OPEN_FAILED || status.doc != NULL;
    ls_net_open_release(job);
    return failed;
  }
  if (status.state != LS_NET_OPEN_DONE || !status.doc) {
    fprintf(stderr, "open state %d error %d\n", status.state, status.error);
    ls_net_open_release(job);
    return 4;
  }
  ls_doc *doc = status.doc;
  double metadata = now();
  // Deliberately release the open job before requesting further pages.
  ls_net_open_release(job);
  if (!ls_document_is_parquet(doc)) {
    ls_close(doc);
    return 5;
  }
  ls_row_count total = ls_row_count_get(doc);
  uint32_t columns = ls_column_count(doc);
  if (columns > 12)
    columns = 12;
  if (!strcmp(mode, "cancel-page")) {
    (void)ls_window_set_columns(doc, total.count - 1, 1, 0, columns);
    pause_ms(100);
    for (int i = 0; i < 20; ++i) {
      double call = now();
      (void)ls_window_set_columns(doc, total.count - 1, 1, 0, columns);
      (void)ls_index_poll(doc);
      if (now() - call >= 200) {
        fprintf(stderr, "UI call blocked\n");
        return 6;
      }
    }
    double closing = now();
    ls_close(doc);
    printf("{\"cancel_ms\":%.3f}\n", now() - closing);
    return now() - closing >= 200;
  }
  uint32_t count = total.count < 48 ? (uint32_t)total.count : 48;
  int error = !strcmp(mode, "page-error");
  if (!window(doc, 0, count, columns, error)) {
    ls_close(doc);
    return 7;
  }
  if (error) {
    ls_close(doc);
    return 0;
  }
  double visible = now();
  if (!total.exact || (strcmp(mode, "types") && !id_equals(doc, 0))) {
    ls_close(doc);
    return 8;
  }
  double jump = now();
  if (strcmp(mode, "first") &&
      (!window(doc, total.count - 1, 1, columns, 0) ||
       (strcmp(mode, "types") && !id_equals(doc, total.count - 1)))) {
    ls_close(doc);
    return 9;
  }
  printf("{\"metadata_ms\":%.3f,\"visible_ms\":%.3f,\"deep_jump_ms\":%.3f,"
         "\"max_ui_call_ms\":%.3f,\"rows\":%llu,\"open_bytes\":%llu}\n",
         metadata - start, visible - start, now() - jump, max_call_ms,
         (unsigned long long)total.count,
         (unsigned long long)status.bytes_fetched);
  ls_close(doc);
  return 0;
}
