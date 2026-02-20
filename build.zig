const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function.
    const exe = b.addExecutable(.{
        .name = "supersearchr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
    });
    const jackett_mod = b.createModule(.{
        .root_source_file = b.path("src/jackett/client.zig"),
    });
    const superseedr_mod = b.createModule(.{
        .root_source_file = b.path("src/superseedr/client.zig"),
    });
    const term_mod = b.createModule(.{
        .root_source_file = b.path("src/tui/term.zig"),
    });
    const torrent_mod = b.createModule(.{
        .root_source_file = b.path("src/structs/torrent.zig"),
    });

    jackett_mod.addImport("torrent", torrent_mod);
    const search_widget_mod = b.createModule(.{
        .root_source_file = b.path("src/tui/widgets/search.zig"),
    });
    search_widget_mod.addImport("term", term_mod);
    const results_widget_mod = b.createModule(.{
        .root_source_file = b.path("src/tui/widgets/results.zig"),
    });
    results_widget_mod.addImport("term", term_mod);
    results_widget_mod.addImport("torrent", torrent_mod);
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/tui/app.zig"),
    });

    app_mod.addImport("config", config_mod);
    app_mod.addImport("jackett", jackett_mod);
    app_mod.addImport("superseedr", superseedr_mod);
    app_mod.addImport("term", term_mod);
    app_mod.addImport("search", search_widget_mod);
    app_mod.addImport("results", results_widget_mod);
    app_mod.addImport("torrent", torrent_mod);

    exe.root_module.addImport("config", config_mod);
    exe.root_module.addImport("jackett", jackett_mod);
    exe.root_module.addImport("superseedr", superseedr_mod);
    exe.root_module.addImport("term", term_mod);
    exe.root_module.addImport("torrent", torrent_mod);
    exe.root_module.addImport("search", search_widget_mod);
    exe.root_module.addImport("results", results_widget_mod);
    exe.root_module.addImport("tui/app", app_mod);

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Test for config module
    const config_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/config.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_config_tests = b.addRunArtifact(config_tests);

    // Test for jackett module
    // Reuse torrent_mod defined above
    const jackett_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/jackett/client.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    jackett_tests.root_module.addImport("torrent", torrent_mod);
    const run_jackett_tests = b.addRunArtifact(jackett_tests);

    // Test for superseedr module
    const superseedr_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/superseedr/client.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_superseedr_tests = b.addRunArtifact(superseedr_tests);

    // Test for search widget
    // Reuse term_mod defined above
    const search_widget_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui/widgets/search.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    search_widget_tests.root_module.addImport("term", term_mod);
    const run_search_widget_tests = b.addRunArtifact(search_widget_tests);

    // Test for results widget
    const results_widget_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui/widgets/results.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    results_widget_tests.root_module.addImport("term", term_mod);
    results_widget_tests.root_module.addImport("torrent", torrent_mod);
    const run_results_widget_tests = b.addRunArtifact(results_widget_tests);

    // Test for app module
    // Reuse modules defined above
    const app_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui/app.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    app_tests.root_module.addImport("config", config_mod);
    app_tests.root_module.addImport("jackett", b.createModule(.{
        .root_source_file = b.path("src/jackett/client.zig"),
    }));
    app_tests.root_module.addImport("superseedr", superseedr_mod);
    app_tests.root_module.addImport("term", term_mod);
    app_tests.root_module.addImport("search", search_widget_mod);
    app_tests.root_module.addImport("results", results_widget_mod);
    app_tests.root_module.addImport("torrent", torrent_mod);
    const run_app_tests = b.addRunArtifact(app_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps does not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_config_tests.step);
    test_step.dependOn(&run_jackett_tests.step);
    test_step.dependOn(&run_superseedr_tests.step);
    test_step.dependOn(&run_search_widget_tests.step);
    test_step.dependOn(&run_results_widget_tests.step);
    test_step.dependOn(&run_app_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
