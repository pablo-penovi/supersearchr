const std = @import("std");

const ImportSpec = struct {
    name: []const u8,
    module: *std.Build.Module,
};

const ModuleTest = struct {
    name: []const u8,
    artifact: *std.Build.Step.Compile,
    run: *std.Build.Step.Run,
};

const CoverageTest = struct {
    name: []const u8,
    artifact: *std.Build.Step.Compile,
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
    strip: bool,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
}

fn addModuleTest(
    b: *std.Build,
    name: []const u8,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
) ModuleTest {
    const artifact = b.addTest(.{
        .name = name,
        .root_module = createTargetedModule(b, root_source_file, target, optimize, strip),
    });

    return .{
        .name = name,
        .artifact = artifact,
        .run = b.addRunArtifact(artifact),
    };
}
pub fn build(b: *std.Build) void {
    const app_version = "0.4.3";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Omit debug symbols from build artifacts") orelse (optimize != .Debug);

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", app_version);
    const build_options_mod = build_options.createModule();

    const config_mod = b.createModule(.{ .root_source_file = b.path("src/config.zig") });
    const compat_mod = b.createModule(.{ .root_source_file = b.path("src/compat.zig") });
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

    addImports(config_mod, &.{
        .{ .name = "compat", .module = compat_mod },
    });
    addImports(debug_log_mod, &.{
        .{ .name = "compat", .module = compat_mod },
    });
    addImports(update_checker_mod, &.{
        .{ .name = "compat", .module = compat_mod },
    });
    addImports(term_mod, &.{
        .{ .name = "compat", .module = compat_mod },
    });
    addImports(theme_mod, &.{
        .{ .name = "term", .module = term_mod },
    });
    addImports(jackett_mod, &.{
        .{ .name = "torrent", .module = torrent_mod },
        .{ .name = "debug_log", .module = debug_log_mod },
        .{ .name = "compat", .module = compat_mod },
    });
    addImports(superseedr_mod, &.{
        .{ .name = "debug_log", .module = debug_log_mod },
        .{ .name = "compat", .module = compat_mod },
    });
    addImports(search_widget_mod, &.{
        .{ .name = "term", .module = term_mod },
        .{ .name = "theme", .module = theme_mod },
        .{ .name = "build_options", .module = build_options_mod },
        .{ .name = "compat", .module = compat_mod },
    });
    addImports(results_widget_mod, &.{
        .{ .name = "term", .module = term_mod },
        .{ .name = "theme", .module = theme_mod },
        .{ .name = "torrent", .module = torrent_mod },
        .{ .name = "compat", .module = compat_mod },
    });
    addImports(panels_mod, &.{
        .{ .name = "term", .module = term_mod },
        .{ .name = "theme", .module = theme_mod },
        .{ .name = "results", .module = results_widget_mod },
        .{ .name = "compat", .module = compat_mod },
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
        .{ .name = "compat", .module = compat_mod },
    });

    const exe = b.addExecutable(.{
        .name = "supersearchr",
        .root_module = createTargetedModule(b, "src/main.zig", target, optimize, strip),
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

    const config_tests = addModuleTest(b, "test-config", "src/config.zig", target, optimize, strip);
    addImports(config_tests.artifact.root_module, &.{
        .{ .name = "compat", .module = compat_mod },
    });

    const jackett_tests = addModuleTest(b, "test-jackett", "src/jackett/client.zig", target, optimize, strip);
    addImports(jackett_tests.artifact.root_module, &.{
        .{ .name = "torrent", .module = torrent_mod },
        .{ .name = "debug_log", .module = debug_log_mod },
        .{ .name = "compat", .module = compat_mod },
    });

    const superseedr_tests = addModuleTest(b, "test-superseedr", "src/superseedr/client.zig", target, optimize, strip);
    addImports(superseedr_tests.artifact.root_module, &.{
        .{ .name = "debug_log", .module = debug_log_mod },
        .{ .name = "compat", .module = compat_mod },
    });

    const update_checker_tests = addModuleTest(b, "test-update-checker", "src/update_checker.zig", target, optimize, strip);
    addImports(update_checker_tests.artifact.root_module, &.{
        .{ .name = "compat", .module = compat_mod },
    });

    const torrent_tests = addModuleTest(b, "test-torrent", "src/structs/torrent.zig", target, optimize, strip);

    const term_tests = addModuleTest(b, "test-term", "src/tui/term.zig", target, optimize, strip);
    addImports(term_tests.artifact.root_module, &.{
        .{ .name = "compat", .module = compat_mod },
    });

    const search_widget_tests = addModuleTest(b, "test-search", "src/tui/widgets/search.zig", target, optimize, strip);
    addImports(search_widget_tests.artifact.root_module, &.{
        .{ .name = "term", .module = term_mod },
        .{ .name = "theme", .module = theme_mod },
        .{ .name = "build_options", .module = build_options_mod },
        .{ .name = "compat", .module = compat_mod },
    });

    const results_widget_tests = addModuleTest(b, "test-results", "src/tui/widgets/results.zig", target, optimize, strip);
    addImports(results_widget_tests.artifact.root_module, &.{
        .{ .name = "term", .module = term_mod },
        .{ .name = "theme", .module = theme_mod },
        .{ .name = "torrent", .module = torrent_mod },
        .{ .name = "compat", .module = compat_mod },
    });

    const theme_tests = addModuleTest(b, "test-theme", "src/tui/theme.zig", target, optimize, strip);
    addImports(theme_tests.artifact.root_module, &.{
        .{ .name = "term", .module = term_mod },
    });

    const panels_tests = addModuleTest(b, "test-panels", "src/tui/panels.zig", target, optimize, strip);
    addImports(panels_tests.artifact.root_module, &.{
        .{ .name = "term", .module = term_mod },
        .{ .name = "theme", .module = theme_mod },
        .{ .name = "results", .module = results_widget_mod },
        .{ .name = "compat", .module = compat_mod },
    });

    const app_tests = addModuleTest(b, "test-app", "src/tui/app.zig", target, optimize, strip);
    const app_tests_jackett_mod = b.createModule(.{ .root_source_file = b.path("src/jackett/client.zig") });
    addImports(app_tests_jackett_mod, &.{
        .{ .name = "torrent", .module = torrent_mod },
        .{ .name = "debug_log", .module = debug_log_mod },
        .{ .name = "compat", .module = compat_mod },
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
        .{ .name = "compat", .module = compat_mod },
    });

    const exe_tests = b.addTest(.{
        .name = "test-main",
        .root_module = createTargetedModule(b, "src/main.zig", target, optimize, false),
    });
    addImports(exe_tests.root_module, &.{
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
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    const test_runs = [_]*std.Build.Step.Run{
        run_exe_tests,
        config_tests.run,
        jackett_tests.run,
        superseedr_tests.run,
        update_checker_tests.run,
        torrent_tests.run,
        term_tests.run,
        theme_tests.run,
        panels_tests.run,
        search_widget_tests.run,
        results_widget_tests.run,
        app_tests.run,
    };
    for (test_runs) |run_test| {
        test_step.dependOn(&run_test.step);
    }

    const coverage_step = b.step("coverage", "Run tests with kcov coverage");
    const coverage_tests = [_]CoverageTest{
        .{ .name = "main", .artifact = exe_tests },
        .{ .name = config_tests.name, .artifact = config_tests.artifact },
        .{ .name = jackett_tests.name, .artifact = jackett_tests.artifact },
        .{ .name = superseedr_tests.name, .artifact = superseedr_tests.artifact },
        .{ .name = update_checker_tests.name, .artifact = update_checker_tests.artifact },
        .{ .name = torrent_tests.name, .artifact = torrent_tests.artifact },
        .{ .name = term_tests.name, .artifact = term_tests.artifact },
        .{ .name = theme_tests.name, .artifact = theme_tests.artifact },
        .{ .name = panels_tests.name, .artifact = panels_tests.artifact },
        .{ .name = search_widget_tests.name, .artifact = search_widget_tests.artifact },
        .{ .name = results_widget_tests.name, .artifact = results_widget_tests.artifact },
        .{ .name = app_tests.name, .artifact = app_tests.artifact },
    };

    const clean_coverage = b.addSystemCommand(&.{ "rm", "-rf", "coverage" });
    const mkdir_coverage = b.addSystemCommand(&.{ "mkdir", "-p" });
    mkdir_coverage.step.dependOn(&clean_coverage.step);
    for (coverage_tests) |coverage_test| {
        coverage_test.artifact.use_llvm = true;
        coverage_test.artifact.root_module.strip = false;
        mkdir_coverage.addArg(b.fmt("coverage/{s}", .{coverage_test.name}));
    }
    mkdir_coverage.addArg("coverage/merged");

    const project_root = b.pathFromRoot(".");
    const kcov_merge = b.addSystemCommand(&.{ "kcov", "--clean", "--merge", "coverage/merged" });
    kcov_merge.step.dependOn(&mkdir_coverage.step);

    for (coverage_tests) |coverage_test| {
        const output_dir = b.fmt("coverage/{s}", .{coverage_test.name});
        const kcov_run = b.addSystemCommand(&.{
            "kcov",
            "--clean",
            b.fmt("--include-path={s}/src", .{project_root}),
            "--exclude-pattern=debug/,/.zig/,/lib/zig/",
        });
        kcov_run.addArg(output_dir);
        kcov_run.addArtifactArg(coverage_test.artifact);
        kcov_run.step.dependOn(&mkdir_coverage.step);

        kcov_merge.addArg(output_dir);
        kcov_merge.step.dependOn(&kcov_run.step);
    }

    coverage_step.dependOn(&kcov_merge.step);
}
