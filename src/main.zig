const std = @import("std");
const compat = @import("compat");
const config = @import("config");
const app = @import("tui/app");

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    if (std.Options.debug_threaded_io) |threaded| {
        threaded.allocator = gpa.allocator();
    }
    defer {
        if (gpa.deinit() != 0) {
            std.debug.print("Memory leak detected\n", .{});
        }
    }

    // Unlike the default global single-threaded `Io`, this one can run
    // concurrent tasks and cancel them; the app cancels its startup Jackett
    // check on exit instead of waiting for it. `environ` keeps PATH lookups
    // (spawning superseedr) working.
    var threaded: std.Io.Threaded = .init(gpa.allocator(), .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    compat.installIo(threaded.io());
    defer compat.installIo(null);

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
    const entry: fn (std.process.Init.Minimal) anyerror!void = main;
    _ = entry;
}
