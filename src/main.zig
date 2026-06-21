const std = @import("std");
const config = @import("config");
const app = @import("tui/app");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    if (std.Options.debug_threaded_io) |threaded| {
        threaded.allocator = gpa.allocator();
    }
    defer {
        if (gpa.deinit() == .leak) {
            std.debug.print("Memory leak detected\n", .{});
        }
    }

    const cfg = config.loadConfig(gpa.allocator()) catch |err| {
        if (err == error.ConfigCreated) {
            return error.ConfigCreated;
        }
        return err;
    };
    defer {
        gpa.allocator().free(cfg.api_key);
        gpa.allocator().free(cfg.api_url);
        gpa.allocator().free(cfg.terminal);
        gpa.allocator().free(cfg.jackett_admin_password);
    }

    try app.run(gpa.allocator(), cfg);
}

test "main entry point has expected signature" {
    const entry: fn () anyerror!void = main;
    _ = entry;
}
