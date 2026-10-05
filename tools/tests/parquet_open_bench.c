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
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  ls_doc *doc = NULL;
  ls_open_options options = { .separator = LS_SNIFF, .quote = LS_SNIFF,
    .header = LS_SNIFF, .index_mode = LS_INDEX_MANUAL, .encoding = LS_ENCODING_AUTO };
  double start = milliseconds();
  if (ls_open(argv[1], &options, &doc) != LS_OK) return 3;
  double metadata = milliseconds();
  ls_row_range window = ls_window_set_columns(doc, 0, 48, 0, 12);
  double visible = milliseconds();
  ls_row_count rows = ls_row_count_get(doc);
  ls_str first = ls_cell(doc, 0, 0);
  printf("%s: metadata %.3f ms, first viewport %.3f ms, rows %llu (%s), served %llu, first %.*s\n",
    argv[1], metadata - start, visible - start, (unsigned long long)rows.count,
    rows.exact ? "exact" : "estimate", (unsigned long long)window.row_count,
    (int)first.len, first.ptr);
  int failed = ls_document_status(doc) != LS_OK || window.row_count == 0;
  ls_close(doc);
  return failed;
}
