const std = @import("std");

const ImportSpec = struct {
    name: []const u8,
    module: *std.Build.Module,
};

const ModuleTest = struct {
    artifact: *std.Build.Step.Compile,
    run: *std.Build.Step.Run,
};

fn addImports(dst: *std.Build.Module, imports: []const ImportSpec) void {
    for (imports) |imp| {
        dst.addImport(imp.name, imp.module);
    }
}

fn createTargetedModule(
    b: *std.Build,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
    });
}

fn addModuleTest(
    b: *std.Build,
    name: []const u8,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ModuleTest {
    const artifact = b.addTest(.{
        .name = name,
        .root_module = createTargetedModule(b, root_source_file, target, optimize),
    });

    return .{
        .artifact = artifact,
        .run = b.addRunArtifact(artifact),
    };
}

pub fn build(b: *std.Build) void {
    const app_version = "0.3.7";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", app_version);
    const build_options_mod = build_options.createModule();

    const config_mod = b.createModule(.{ .root_source_file = b.path("src/config.zig") });
    const jackett_mod = b.createModule(.{ .root_source_file = b.path("src/jackett/client.zig") });
    const superseedr_mod = b.createModule(.{ .root_source_file = b.path("src/superseedr/client.zig") });
    const term_mod = b.createModule(.{ .root_source_file = b.path("src/tui/term.zig") });
    const theme_mod = b.createModule(.{ .root_source_file = b.path("src/tui/theme.zig") });
    const panels_mod = b.createModule(.{ .root_source_file = b.path("src/tui/panels.zig") });
    const torrent_mod = b.createModule(.{ .root_source_file = b.path("src/structs/torrent.zig") });
    const debug_log_mod = b.createModule(.{ .root_source_file = b.path("src/debug/log.zig") });
    const update_checker_mod = b.createModule(.{ .root_source_file = b.path("src/update_checker.zig") });
    const search_widget_mod = b.createModule(.{ .root_source_file = b.path("src/tui/widgets/search.zig") });
    const results_widget_mod = b.createModule(.{ .root_source_file = b.path("src/tui/widgets/results.zig") });
    const app_mod = b.createModule(.{ .root_source_file = b.path("src/tui/app.zig") });

    addImports(theme_mod, &.{
        .{ .name = "term", .module = term_mod },
    });
    addImports(jackett_mod, &.{
        .{ .name = "torrent", .module = torrent_mod },
        .{ .name = "debug_log", .module = debug_log_mod },
    });
    addImports(superseedr_mod, &.{
        .{ .name = "debug_log", .module = debug_log_mod },
    });
    addImports(search_widget_mod, &.{
        .{ .name = "term", .module = term_mod },
        .{ .name = "theme", .module = theme_mod },
        .{ .name = "build_options", .module = build_options_mod },
    });
    addImports(results_widget_mod, &.{
        .{ .name = "term", .module = term_mod },
        .{ .name = "theme", .module = theme_mod },
        .{ .name = "torrent", .module = torrent_mod },
    });
    addImports(panels_mod, &.{
        .{ .name = "term", .module = term_mod },
        .{ .name = "theme", .module = theme_mod },
        .{ .name = "results", .module = results_widget_mod },
    });
    addImports(app_mod, &.{
        .{ .name = "config", .module = config_mod },
        .{ .name = "jackett", .module = jackett_mod },
        .{ .name = "superseedr", .module = superseedr_mod },
        .{ .name = "term", .module = term_mod },
        .{ .name = "theme", .module = theme_mod },
        .{ .name = "panels", .module = panels_mod },
        .{ .name = "search", .module = search_widget_mod },
        .{ .name = "results", .module = results_widget_mod },
        .{ .name = "update_checker", .module = update_checker_mod },
        .{ .name = "build_options", .module = build_options_mod },
        .{ .name = "torrent", .module = torrent_mod },
        .{ .name = "debug_log", .module = debug_log_mod },
    });

    const exe = b.addExecutable(.{
        .name = "supersearchr",
        .root_module = createTargetedModule(b, "src/main.zig", target, optimize),
    });
    addImports(exe.root_module, &.{
        .{ .name = "config", .module = config_mod },
        .{ .name = "jackett", .module = jackett_mod },
        .{ .name = "superseedr", .module = superseedr_mod },
        .{ .name = "term", .module = term_mod },
        .{ .name = "theme", .module = theme_mod },
        .{ .name = "torrent", .module = torrent_mod },
        .{ .name = "search", .module = search_widget_mod },
        .{ .name = "results", .module = results_widget_mod },
        .{ .name = "tui/app", .module = app_mod },
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const config_tests = addModuleTest(b, "test-config", "src/config.zig", target, optimize);

    const jackett_tests = addModuleTest(b, "test-jackett", "src/jackett/client.zig", target, optimize);
    addImports(jackett_tests.artifact.root_module, &.{
        .{ .name = "torrent", .module = torrent_mod },
        .{ .name = "debug_log", .module = debug_log_mod },
    });

    const superseedr_tests = addModuleTest(b, "test-superseedr", "src/superseedr/client.zig", target, optimize);
    addImports(superseedr_tests.artifact.root_module, &.{
        .{ .name = "debug_log", .module = debug_log_mod },
    });

    const update_checker_tests = addModuleTest(b, "test-update-checker", "src/update_checker.zig", target, optimize);

    const search_widget_tests = addModuleTest(b, "test-search", "src/tui/widgets/search.zig", target, optimize);
    addImports(search_widget_tests.artifact.root_module, &.{
        .{ .name = "term", .module = term_mod },
        .{ .name = "theme", .module = theme_mod },
        .{ .name = "build_options", .module = build_options_mod },
    });

    const results_widget_tests = addModuleTest(b, "test-results", "src/tui/widgets/results.zig", target, optimize);
    addImports(results_widget_tests.artifact.root_module, &.{
        .{ .name = "term", .module = term_mod },
        .{ .name = "theme", .module = theme_mod },
        .{ .name = "torrent", .module = torrent_mod },
    });

    const theme_tests = addModuleTest(b, "test-theme", "src/tui/theme.zig", target, optimize);
    addImports(theme_tests.artifact.root_module, &.{
        .{ .name = "term", .module = term_mod },
    });

    const panels_tests = addModuleTest(b, "test-panels", "src/tui/panels.zig", target, optimize);
    addImports(panels_tests.artifact.root_module, &.{
        .{ .name = "term", .module = term_mod },
        .{ .name = "theme", .module = theme_mod },
        .{ .name = "results", .module = results_widget_mod },
    });

    const app_tests = addModuleTest(b, "test-app", "src/tui/app.zig", target, optimize);
    const app_tests_jackett_mod = b.createModule(.{ .root_source_file = b.path("src/jackett/client.zig") });
    addImports(app_tests_jackett_mod, &.{
        .{ .name = "torrent", .module = torrent_mod },
        .{ .name = "debug_log", .module = debug_log_mod },
    });
    addImports(app_tests.artifact.root_module, &.{
        .{ .name = "config", .module = config_mod },
        .{ .name = "jackett", .module = app_tests_jackett_mod },
        .{ .name = "superseedr", .module = superseedr_mod },
        .{ .name = "term", .module = term_mod },
        .{ .name = "theme", .module = theme_mod },
        .{ .name = "panels", .module = panels_mod },
        .{ .name = "search", .module = search_widget_mod },
        .{ .name = "results", .module = results_widget_mod },
        .{ .name = "update_checker", .module = update_checker_mod },
        .{ .name = "build_options", .module = build_options_mod },
        .{ .name = "torrent", .module = torrent_mod },
        .{ .name = "debug_log", .module = debug_log_mod },
    });

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    const test_runs = [_]*std.Build.Step.Run{
        run_exe_tests,
        config_tests.run,
        jackett_tests.run,
        superseedr_tests.run,
        update_checker_tests.run,
        theme_tests.run,
        panels_tests.run,
        search_widget_tests.run,
        results_widget_tests.run,
        app_tests.run,
    };
    for (test_runs) |run_test| {
        test_step.dependOn(&run_test.step);
    }
}
