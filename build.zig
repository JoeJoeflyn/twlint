const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // === Run JS generator at build time ===
    // Produces src/generated_registry.zig with all Tailwind v4 classes,
    // prefixes, and dynamic prefixes from the official IntelliSense.
    const generate_step = b.addSystemCommand(&.{
        "node", "tools/generate-registry.js",
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Import the generated file as a named module accessible via @import("generated_registry")
    const generated_module = b.createModule(.{
        .root_source_file = b.path("src/generated_registry.zig"),
    });
    root_module.addImport("generated_registry", generated_module);

    const exe = b.addExecutable(.{
        .name = "twlint",
        .root_module = root_module,
    });
    // Ensure the generator runs before compilation
    exe.step.dependOn(&generate_step.step);
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = root_module,
    });
    tests.step.dependOn(&generate_step.step);

    const rules_test_module = b.createModule(.{
        .root_source_file = b.path("src/rules_test_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    rules_test_module.addImport("generated_registry", generated_module);

    const rules_tests = b.addTest(.{
        .root_module = rules_test_module,
    });
    rules_tests.step.dependOn(&generate_step.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(rules_tests).step);
}
