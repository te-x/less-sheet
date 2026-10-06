#define _POSIX_C_SOURCE 200809L
#include <lesssheet.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double milliseconds(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000.0 + t.tv_nsec / 1000000.0;
}

static int compare(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return (x > y) - (x < y);
}

static int measure(ls_doc *doc, const char *name, unsigned frames,
                   uint64_t step, uint64_t rows, uint32_t columns) {
  double samples[512];
  unsigned long long bytes = 0;
  for (unsigned i = 0; i < frames; ++i) {
    uint64_t first = ((uint64_t)i * step) % (rows - 48);
    double start = milliseconds();
    ls_row_range window = ls_window_set_columns(doc, first, 48, 0, columns);
    samples[i] = milliseconds() - start;
    if (window.row_count != 48 || ls_document_status(doc) != LS_OK) return 1;
    for (uint64_t row = first; row < first + 48; ++row)
      for (uint32_t col = 0; col < columns; ++col)
        bytes += ls_cell(doc, row, col).len;
  }
  qsort(samples, frames, sizeof(*samples), compare);
  printf("%s: %u windows, median %.3f ms, p95 %.3f ms, max %.3f ms, %llu cell bytes\n",
         name, frames, samples[frames / 2], samples[(frames - 1) * 95 / 100],
         samples[frames - 1], bytes);
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 2 || argc > 3) return 2;
  unsigned frames = argc == 3 ? (unsigned)atoi(argv[2]) : 120;
  if (frames < 2 || frames > 512) return 2;
  ls_doc *doc = NULL;
  ls_open_options options = { .separator = LS_SNIFF, .quote = LS_SNIFF,
    .header = LS_SNIFF, .index_mode = LS_INDEX_MANUAL, .encoding = LS_ENCODING_AUTO };
  if (ls_open(argv[1], &options, &doc) != LS_OK) return 3;
  uint64_t rows = ls_row_count_get(doc).count;
  uint32_t columns = ls_column_count(doc);
  if (rows <= 48 || columns == 0) { ls_close(doc); return 2; }
  if (columns > 18) columns = 18;
  int failed = measure(doc, "short scroll", frames, 8, rows, columns);
  if (!failed) failed = measure(doc, "backward scroll", frames,
                               rows - 48 - 8, rows, columns);
  // Force page-cache misses without assuming how a writer sizes row groups.
  if (!failed) failed = measure(doc, "distant jumps", frames,
                               (rows - 48) / frames, rows, columns);
  ls_close(doc);
  return failed;
}
