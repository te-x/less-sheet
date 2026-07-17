/*
 * less-sheet Linux network / TLS probe
 * (ARCH-backend-linux-portability, decision 5 / acceptance criterion H3).
 *
 * A minimal host program that opens a real HTTPS CSV / .csv.gz over the network
 * through the ls_open_url_* async ABI and prints the first rows. Its ONLY job is
 * the human-runtime check the gate cannot make headlessly: that on a real Linux
 * host the system CA / cert store loads and std.crypto.tls verifies against a
 * real range-serving host (Linux reads the trust store differently than macOS),
 * and that the first rows come back. Real HTTP is a fake-seam-only path in the
 * gate on every OS, and a cross-compiled binary is not executable on the build
 * host, so this is verified by the human on real hardware.
 *
 * This is thin C glue over the frozen C ABI (api/lesssheet.h). The load-bearing
 * Zig network code it exercises (net.zig) is gate-covered by the G1/G2 library
 * cross-compile assertion; only the TLS RUNTIME behaviour is checked here.
 *
 * Build + ship with tools/netprobe/netprobe_on (the same cross-compile-and-ship
 * mechanism as tools/bench/bench_lesssheet_on). Direct usage of the built binary:
 *
 *     netprobe <https-url> [max_rows] [max_cols]
 *
 * Exit 0 iff the open reached LS_NET_OPEN_DONE; non-zero otherwise (printing the
 * ls_net_status code and, for an HTTP error, the numeric HTTP status).
 */
#include "lesssheet.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static void nap_ms(long ms) {
    struct timespec t = { ms / 1000, (ms % 1000) * 1000000L };
    nanosleep(&t, NULL);
}

static const char *state_name(ls_net_open_state s) {
    switch (s) {
        case LS_NET_OPEN_PENDING:   return "PENDING";
        case LS_NET_OPEN_FETCHING:  return "FETCHING";
        case LS_NET_OPEN_DONE:      return "DONE";
        case LS_NET_OPEN_FAILED:    return "FAILED";
        case LS_NET_OPEN_CANCELLED: return "CANCELLED";
        default:                    return "?";
    }
}

static const char *error_name(ls_net_status e) {
    switch (e) {
        case LS_NET_OK:                       return "OK";
        case LS_NET_ERROR_INVALID_ARGUMENT:   return "INVALID_ARGUMENT";
        case LS_NET_ERROR_UNREACHABLE:        return "UNREACHABLE (DNS/TCP/TLS handshake)";
        case LS_NET_ERROR_TIMEOUT:            return "TIMEOUT";
        case LS_NET_ERROR_HTTP_STATUS:        return "HTTP_STATUS";
        case LS_NET_ERROR_TOO_MANY_REDIRECTS: return "TOO_MANY_REDIRECTS";
        case LS_NET_ERROR_IO:                 return "IO (spool)";
        case LS_NET_ERROR_CANCELLED:          return "CANCELLED";
        default:                              return "?";
    }
}

/* Print an ls_str cell, tab-separated; NULL/empty prints nothing. */
static void put_cell(uint32_t col, ls_str s) {
    fputs(col ? "\t" : "", stdout);
    if (s.ptr && s.len) fwrite(s.ptr, 1, s.len, stdout);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <https-url> [max_rows] [max_cols]\n", argv[0]);
        return 2;
    }
    const char *url = argv[1];
    uint32_t max_rows = (argc > 2) ? (uint32_t)strtoul(argv[2], NULL, 10) : 10;
    uint32_t max_cols = (argc > 3) ? (uint32_t)strtoul(argv[3], NULL, 10) : 16;

    printf("[netprobe] opening %s\n", url);
    fflush(stdout);

    ls_net_open_job *job = ls_open_url_start(url, strlen(url), NULL);
    if (!job) {
        fprintf(stderr, "[netprobe] ls_open_url_start returned NULL (handle allocation failed)\n");
        return 1;
    }

    /* Poll to a terminal state with a wall-clock safety cap. A TLS / CA-store
     * failure surfaces as LS_NET_OPEN_FAILED(UNREACHABLE) here, not a hang. */
    const int cap_ms = 60000;
    int waited = 0;
    ls_net_open_state last = (ls_net_open_state)-1;
    ls_net_open_status st = ls_net_open_poll(job);
    while (st.state == LS_NET_OPEN_PENDING || st.state == LS_NET_OPEN_FETCHING) {
        if (st.state != last) {
            printf("[netprobe] state=%s bytes_fetched=%llu bytes_total=%llu\n",
                   state_name(st.state),
                   (unsigned long long)st.bytes_fetched,
                   (unsigned long long)st.bytes_total);
            fflush(stdout);
            last = st.state;
        }
        if (waited >= cap_ms) {
            fprintf(stderr, "[netprobe] gave up after %d ms, still %s\n", cap_ms, state_name(st.state));
            ls_net_open_cancel(job);
            ls_net_open_release(job);
            return 1;
        }
        nap_ms(25);
        waited += 25;
        st = ls_net_open_poll(job);
    }

    if (st.state != LS_NET_OPEN_DONE || !st.doc) {
        fprintf(stderr, "[netprobe] open %s: error=%s http_status=%d\n",
                state_name(st.state), error_name(st.error), st.http_status);
        ls_net_open_release(job);
        return 1;
    }

    /* DONE: the connection was made, TLS verified, and the head fetched.
     * Materialize and print the first viewport (O(viewport), never O(file)). */
    ls_doc *doc = st.doc;
    uint32_t cols = ls_column_count(doc);
    uint32_t show_cols = cols < max_cols ? cols : max_cols;
    ls_row_range r = ls_window_set(doc, 0, max_rows);

    printf("[netprobe] DONE: bytes_total=%llu columns=%u; first %llu row(s):\n",
           (unsigned long long)st.bytes_total, cols,
           (unsigned long long)r.row_count);

    for (uint32_t c = 0; c < show_cols; c++) put_cell(c, ls_header_cell(doc, c));
    fputc('\n', stdout);
    for (uint64_t i = 0; i < r.row_count; i++) {
        for (uint32_t c = 0; c < show_cols; c++) put_cell(c, ls_cell(doc, i, c));
        fputc('\n', stdout);
    }
    fflush(stdout);

    ls_close(doc);            /* the DONE job's doc has its own lifecycle */
    ls_net_open_release(job); /* release the job handle exactly once */
    printf("[netprobe] OK\n");
    return 0;
}
