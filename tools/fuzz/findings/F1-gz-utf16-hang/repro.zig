const std = @import("std");
const api = @import("api");

pub fn main(init: std.process.Init) !void {
    var it: std.process.Args.Iterator = .init(init.minimal.args);
    _ = it.next();
    const path = it.next().?;
    const sep = try std.fmt.parseInt(i32, it.next().?, 10);
    const quote = try std.fmt.parseInt(i32, it.next().?, 10);
    const header = try std.fmt.parseInt(i32, it.next().?, 10);
    const enc = try std.fmt.parseInt(i32, it.next().?, 10);
    const im = try std.fmt.parseInt(i32, it.next().?, 10);
    const opts: api.OpenOptions = .{ .separator = sep, .quote = quote, .header = header, .encoding = enc, .index_mode = im };
    var buf: [1024]u8 = undefined;
    const p = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    std.debug.print("opening sep={d} quote={d} header={d} enc={d} index={d} ... ", .{ sep, quote, header, enc, im });
    var doc: ?*api.Doc = null;
    const st = api.ls_open(p.ptr, &opts, &doc);
    std.debug.print("status={t}", .{st});
    if (doc) |d| {
        const rc = api.ls_row_count_get(d);
        std.debug.print(" rows={d} exact={} cols={d}", .{ rc.count, rc.exact, api.ls_column_count(d) });
        api.ls_close(d);
    }
    std.debug.print("\nRETURNED\n", .{});
}
