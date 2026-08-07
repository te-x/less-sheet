/*
 * Core-only resting memory: what less-sheet's engine costs with a document
 * open, WITHOUT any UI.
 *
 * Why it exists: the app's resting footprint is dominated by the window, not
 * the data — on macOS over half of it is CoreAnimation layer backing, which
 * scales with the display and is allocated by the OS, not by us. Reporting one
 * total therefore answers "what does a native window cost on this platform",
 * which is not the question a reader of a CSV viewer's benchmark is asking.
 * Splitting it into core + UI separates the part that is ours (and should be
 * comparable across platforms, since it is the same Zig code) from the part
 * that is the toolkit's (and legitimately differs).
 *
 * Deliberately does NOT measure its own memory. It performs the same work the
 * app makes the core perform — open, materialize a viewport, run the index scan
 * to completion — then prints READY and idles, so the SAME external sampler and
 * the SAME metric used on the full app can read it (macOS phys_footprint via
 * vmmap; Linux Pss_Anon via smaps_rollup). Two numbers produced by one method
 * can be subtracted; two numbers produced by two methods cannot.
 *
 * Build (macOS):
 *   cc -O2 -I api tools/bench/coremem.c backend/zig-out/lib/liblesssheet.a -o coremem
 * Run:
 *   coremem <file>        # prints READY, then idles until killed
 */
#include "lesssheet.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static void nap_us(long us) {
    struct timespec t = {0, us * 1000L};
    nanosleep(&t, NULL);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <csv-or-csv.gz>\n", argv[0]);
        return 2;
    }

    ls_doc *doc = NULL;
    if (ls_open(argv[1], NULL, &doc) != LS_OK || !doc) {
        fprintf(stderr, "open failed: %s\n", argv[1]);
        return 1;
    }

    /* The viewport the app materializes on first paint. 100 rows is the
     * harness convention in less_sheet_bench.py; the exact number barely
     * matters here because a window is O(viewport), which is the point. */
    ls_window_set(doc, 0, 100);

    /* Run the background index to completion. Resting memory is only
     * meaningful once the scan has finished — sampling during it measures how
     * far the scan got, which tracks page-cache warmth rather than the
     * program. The app-side harness learned this the hard way. */
    for (;;) {
        if (ls_index_poll(doc).complete) break;
        nap_us(500);
    }

    ls_row_count rc = ls_row_count_get(doc);
    printf("READY rows=%llu cols=%u\n",
           (unsigned long long)rc.count, ls_column_count(doc));
    fflush(stdout);

    /* Idle holding the document open — this is the state being measured. The
     * sampler kills us. */
    for (;;) nap_us(200000);
}
