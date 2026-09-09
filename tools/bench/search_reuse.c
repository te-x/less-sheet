/* Public-ABI regression and timing probe for Find/Filter reuse, including sort.
 * cc -O2 -Wall -Wextra -Werror -I api tools/bench/search_reuse.c \
 *    backend/zig-out/lib/liblesssheet.a -lpthread -lm -o /tmp/search-reuse
 * /tmp/search-reuse [--baseline | --fixture FILE]
 * Baseline mode permits rescans but still checks counts and navigation.
 * --fixture checks an existing (possibly gzipped) four-million-row fixture
 * with the same repeating records generated below, without modifying it.
 */
#define _POSIX_C_SOURCE 200809L
#include "lesssheet.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static bool baseline;
static const uint64_t rows = 4000000;

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000.0 + t.tv_nsec / 1000000.0;
}

static void tick(void) {
    struct timespec t = {0, 1000000};
    nanosleep(&t, NULL);
}

static ls_doc *open_doc(const char *path) {
    ls_doc *doc = NULL;
    ls_open_options opts = {LS_SNIFF, LS_SNIFF, LS_HEADER_ON,
                            LS_INDEX_MANUAL, LS_ENCODING_AUTO};
    assert(ls_open(path, &opts, &doc) == LS_OK);
    return doc;
}

static ls_search_request text(const char *value) {
    ls_search_request req = {0};
    req.kind = LS_SEARCH_TEXT;
    req.value_ptr = (const uint8_t *)value;
    req.value_len = strlen(value);
    return req;
}

static ls_search_status search_done(ls_doc *doc) {
    double start = now_ms();
    for (;;) {
        ls_search_status s = ls_search_poll(doc);
        if (s.state == LS_SEARCH_DONE) return s;
        assert(s.state == LS_SEARCH_SCANNING && now_ms() - start < 30000);
        tick();
    }
}

static ls_filter_status filter_done(ls_doc *doc) {
    double start = now_ms();
    for (;;) {
        ls_filter_status s = ls_filter_poll(doc);
        if (s.state == LS_FILTER_DONE) return s;
        assert((s.state == LS_FILTER_SCANNING ||
                (s.state == LS_FILTER_CANCELLED && ls_sort_poll(doc).state == LS_SORT_BUILDING))
               && now_ms() - start < 30000);
        tick();
    }
}

static void search(ls_doc *doc, ls_search_request req, uint64_t total, bool reused) {
    assert(ls_search_start(doc, &req));
    ls_search_status s = ls_search_poll(doc);
    assert(s.nav == LS_SEARCH_NAV_NONE && s.position == 0);
    if (reused && !baseline) assert(s.state == LS_SEARCH_DONE);
    s = search_done(doc);
    assert(s.total == total && s.total_exact);
}

static void filter(ls_doc *doc, ls_search_request req, uint64_t total, bool reused) {
    assert(ls_filter_set(doc, &req));
    if (reused && !baseline) assert(ls_filter_poll(doc).state == LS_FILTER_DONE);
    ls_search_status s = ls_search_poll(doc);
    assert(s.state == LS_SEARCH_IDLE && s.total == 0 && s.position == 0);
    ls_filter_status f = filter_done(doc);
    assert(f.total == total && f.total_exact);
}

static void nav(ls_doc *doc, uint64_t anchor, ls_search_dir dir, uint64_t row,
                uint64_t position, uint32_t col) {
    ls_search_nav(doc, anchor, dir);
    double start = now_ms();
    ls_search_status s = ls_search_poll(doc);
    while (s.nav == LS_SEARCH_NAV_SEARCHING) {
        assert(now_ms() - start < 30000);
        tick();
        s = ls_search_poll(doc);
    }
    assert(s.nav == LS_SEARCH_NAV_FOUND && s.found_row == row);
    assert(s.position == position && s.found_col == col);
}

static void completed(const char *path) {
    ls_doc *doc = open_doc(path);
    ls_search_request req = text("needle");
    double start = now_ms();
    search(doc, req, rows * 3 / 4, false);
    printf("initial search: %.3f ms\n", now_ms() - start);
    start = now_ms();
    ls_search_cancel(doc);
    search(doc, req, rows * 3 / 4, true);
    printf("reopen search: %.3f ms\n", now_ms() - start);
    nav(doc, 0, LS_SEARCH_FORWARD, 0, 1, 0);
    // The UI submits a different predicate when entering Where. Returning to
    // Find must retain the text count, even if Where was interrupted.
    ls_search_request where = text("");
    where.kind = LS_SEARCH_PREDICATE;
    where.op = LS_SEARCH_OP_EQ;
    for (unsigned i = 0; i < 4; ++i) {
        assert(ls_search_start(doc, &where));
        if (i == 0) assert(search_done(doc).total == 0);
        start = now_ms();
        search(doc, req, rows * 3 / 4, true);
        printf("Where to Find: %.3f ms\n", now_ms() - start);
        nav(doc, rows, LS_SEARCH_BACKWARD, rows - 2, rows * 3 / 4, 0);
    }
    search(doc, where, 0, true);
    search(doc, req, rows * 3 / 4, true);
    start = now_ms();
    filter(doc, req, rows * 3 / 4, true);
    printf("search to filter: %.3f ms\n", now_ms() - start);
    start = now_ms();
    filter(doc, req, rows * 3 / 4, true);
    printf("reapply filter: %.3f ms\n", now_ms() - start);
    search(doc, req, rows * 3 / 4, true);
    nav(doc, rows * 3 / 4, LS_SEARCH_BACKWARD, rows * 3 / 4 - 1, rows * 3 / 4, 0);
    ls_window_set(doc, rows * 3 / 4 - 1, 1);
    assert(ls_source_row(doc, rows * 3 / 4 - 1) == rows - 2);
    ls_filter_clear(doc);
    assert(ls_filter_poll(doc).state == LS_FILTER_IDLE && ls_filter_poll(doc).total == 0);
    start = now_ms();
    search(doc, req, rows * 3 / 4, true);
    printf("filter to search: %.3f ms\n", now_ms() - start);
    nav(doc, rows, LS_SEARCH_BACKWARD, rows - 2, rows * 3 / 4, 0);

    // Case, scope, mode, column, operator, value, and filter context matter.
    req.case_sensitive = true;
    search(doc, req, rows / 2, false);
    uint32_t scope[] = {0};
    req.scope_ptr = scope;
    req.scope_len = 1;
    search(doc, req, rows / 4, false);
    filter(doc, req, rows / 4, true);
    ls_filter_clear(doc);
    search(doc, req, rows / 4, true);
    scope[0] = 1;
    search(doc, req, rows / 4, false);
    nav(doc, 0, LS_SEARCH_FORWARD, 1, 1, 1);
    req = text("needle");
    req.kind = LS_SEARCH_PREDICATE;
    req.op = LS_SEARCH_OP_EQ;
    req.column = 0;
    search(doc, req, rows / 2, false);
    filter(doc, req, rows / 2, true);
    req.column = 1;
    search(doc, req, 0, false);
    search(doc, req, 0, true);
    ls_filter_clear(doc);
    search(doc, req, rows / 4, false); // never reuse an intersection globally
    req.op = LS_SEARCH_OP_NE;
    search(doc, req, rows * 3 / 4, false);
    req = text("absent");
    search(doc, req, 0, false);
    search(doc, req, 0, true);
    filter(doc, req, 0, true);
    ls_close(doc);
}

static void partial(const char *path) {
    ls_doc *doc = open_doc(path);
    ls_search_request req = text("needle");
    assert(ls_search_start(doc, &req));
    double start = now_ms();
    while (ls_search_poll(doc).total == 0) {
        assert(now_ms() - start < 30000);
        tick();
    }
    ls_search_cancel(doc);
    ls_search_status stopped = ls_search_poll(doc);
    ls_search_request where = text("");
    where.kind = LS_SEARCH_PREDICATE;
    assert(ls_search_start(doc, &where));
    assert(ls_search_start(doc, &req));
    if (!baseline) {
        ls_search_status resumed_search = ls_search_poll(doc);
        assert(resumed_search.total >= stopped.total);
        assert(resumed_search.progress >= stopped.progress);
    }
    assert(ls_filter_set(doc, &req));
    ls_filter_status resumed = ls_filter_poll(doc);
    if (!baseline) {
        assert(resumed.total >= stopped.total);
        assert(resumed.progress >= stopped.progress);
    }
    assert(filter_done(doc).total == rows * 3 / 4);
    ls_close(doc);
    doc = open_doc(path);
    for (unsigned i = 0; i < 30; ++i) {
        assert(ls_search_start(doc, &req));
        tick();
        ls_search_cancel(doc);
        assert(ls_search_start(doc, &req));
        assert(ls_filter_set(doc, &req));
        tick();
        ls_filter_clear(doc);
    }
    search(doc, req, rows * 3 / 4, false);
    ls_close(doc);
}

static void oversized(const char *path) {
    FILE *file = fopen(path, "w");
    assert(file);
    fputs("value\n", file);
    for (unsigned i = 0; i < LS_WINDOW_ROW_SCAN_MAX_BYTES + 1024; ++i) fputc('x', file);
    fputs("needle\nplain\nneedle\n", file);
    assert(fclose(file) == 0);
    ls_doc *doc = open_doc(path);
    ls_search_request req = text("needle");
    search(doc, req, 2, false);
    filter(doc, req, 2, true);
    ls_window_set(doc, 0, 2);
    assert(ls_source_row(doc, 0) == 0 && ls_source_row(doc, 1) == 2);
    ls_filter_clear(doc);
    filter(doc, req, 2, true);
    ls_window_set(doc, 0, 2);
    assert(ls_source_row(doc, 0) == 0 && ls_source_row(doc, 1) == 2);
    ls_close(doc);
}

static void sort_done(ls_doc *doc) {
    double start = now_ms();
    while (ls_sort_poll(doc).state != LS_SORT_ACTIVE) {
        assert(ls_sort_poll(doc).state == LS_SORT_BUILDING && now_ms() - start < 30000);
        tick();
    }
}

static void sorted(const char *path) {
    FILE *file = fopen(path, "w");
    assert(file);
    fputs("a,b,id\nneedle,other,3\nplain,needle,1\nNEEDLE,other,2\nplain,other,0\n", file);
    assert(fclose(file) == 0);
    ls_doc *doc = open_doc(path);
    ls_search_request req = text("needle");
    assert(ls_sort_set(doc, 2, LS_SORT_ASCENDING));
    sort_done(doc);
    search(doc, req, 3, false);
    nav(doc, 0, LS_SEARCH_FORWARD, 1, 1, 1);
    ls_search_cancel(doc);
    search(doc, req, 3, true);
    nav(doc, 4, LS_SEARCH_BACKWARD, 3, 3, 0);
    ls_search_request where = text("1");
    where.kind = LS_SEARCH_PREDICATE;
    where.column = 2;
    search(doc, where, 1, false);
    for (unsigned i = 0; i < 4; ++i) {
        search(doc, req, 3, true);
        nav(doc, 0, LS_SEARCH_FORWARD, 1, 1, 1);
        nav(doc, 4, LS_SEARCH_BACKWARD, 3, 3, 0);
        search(doc, where, 1, true);
        nav(doc, 0, LS_SEARCH_FORWARD, 1, 1, 2);
    }
    search(doc, req, 3, true);
    filter(doc, req, 3, true);
    sort_done(doc);
    filter(doc, req, 3, true);
    if (!baseline) assert(ls_sort_poll(doc).state == LS_SORT_ACTIVE);
    search(doc, req, 3, false);
    nav(doc, 0, LS_SEARCH_FORWARD, 0, 1, 1);
    search(doc, req, 3, true);
    nav(doc, 3, LS_SEARCH_BACKWARD, 2, 3, 0);
    search(doc, where, 1, false);
    search(doc, req, 3, true);
    nav(doc, 3, LS_SEARCH_BACKWARD, 2, 3, 0);
    assert(ls_sort_set(doc, 2, LS_SORT_DESCENDING));
    sort_done(doc);
    assert(ls_search_poll(doc).state == LS_SEARCH_IDLE);
    search(doc, req, 3, false);
    nav(doc, 0, LS_SEARCH_FORWARD, 0, 1, 0);
    ls_sort_clear(doc);
    ls_filter_clear(doc);
    search(doc, req, 3, true);
    nav(doc, 0, LS_SEARCH_FORWARD, 0, 1, 0);
    ls_close(doc);
}

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "--fixture") == 0) {
        completed(argv[2]);
        partial(argv[2]);
        puts("fixture reuse checks passed");
        return 0;
    }
    baseline = argc == 2 && strcmp(argv[1], "--baseline") == 0;
    assert(argc == 1 || baseline);
    setvbuf(stdout, NULL, _IOLBF, 0);
    char path[] = "/tmp/less-sheet-reuse-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0);
    FILE *file = fdopen(fd, "w");
    assert(file);
    fputs("a,b,id\n", file);
    for (uint64_t i = 0; i < rows / 4; ++i)
        fputs("needle,other,0\nplain,needle,1\nNEEDLE,other,2\nplain,other,3\n", file);
    assert(fclose(file) == 0);
    completed(path);
    partial(path);
    oversized(path);
    sorted(path);
    assert(unlink(path) == 0);
    puts("search reuse checks passed (including sort)");
    return 0;
}
