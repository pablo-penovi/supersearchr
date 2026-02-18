## Tooling

This project is compiled using Zig 0.15.2.
**CRITICAL**: It is essential to only use syntax, objects and functions that are compatible with Zig 0.15.2. It's wise to search in the Zig docs: https://ziglang.org/documentation/0.15.2/

## Coding rules

- Do not use *std.Arraylist({type}).init(allocator)* to initialize ArrayList. This is INVALID in Zig 0.15.2. Instead, use *std.ArrayList({type}) = .{}*
- When appending an item to an ArrayList, do not use *{array}.append(item)*. This is INVALID in Zig 0.15.2. Instead, use *{array}.append(allocator, item)*
- When using this structure:
```zig
// the "list" variable in this example is a std.ArrayList that you receive from another function
defer {
    for (list.items) |*inner| {
        inner.deinit(allocator);
    }
    list.deinit(allocator);
}
```
make sure the capture is a var (|*{name}|) and not a const (|{name}|)

- When adding a new module with tests, add a corresponding test section in build.zig following the pattern of existing tests (config_tests, jackett_tests, superseedr_tests, search_widget_tests, results_widget_tests) and dependOn it in the test_step

## Running Tests

- Always run tests with `zig build test --summary all` to see detailed output including test names and pass/fail status
- Do not use `std.debug.print` for output in tests or production code unless explicitly asked by the user or the plan

## Workflows

### Starting a new feature

When the user asks you to start a new feature, he should tell you what the feature is about. If he forgets, ask him for it.

**MANDATORY**: These steps should ALWAYS be executed first when starting a new task, and should always be the first steps when making a plan for a new task:

1. If current branch is not main, and has uncommitted changes or unpushed commits, inform user, stop and await instructions
2. If current branch is not main, switch to main
3. If main has uncomitted changes or unpushed commits, inform user, stop and await instructions
4. Pull latest changes from main
5. Checkout a new branch with the format "feature/{succint name for task}" (ensure branch doesn't exist already in local or remote)
6. Push the branch to create it on remote

### Finishing a feature

**MANDATORY**: At some point, the user will ask you to finish or finalize a feature. At this point, you should:

1. Run corresponding day tests to ensure they pass. If they don't, investigate, diagnose, but DO NOT FIX. Inform the user of your findings and the changes that you think would fix the issue.
2. If tests pass, commit and push any uncommitted changes and push any unpushed commits
3. Create a PR using GitHub CLI. Be sure to adequately describe the changes in the PR description. The PR title should be descriptive but short
