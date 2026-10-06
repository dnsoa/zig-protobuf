const std = @import("std");
const builtin = @import("builtin");

pub const PROTOC_VERSION = "32.1";

pub fn getProtocDependency(b: *std.Build) !?*std.Build.Dependency {
    const os: ?[]const u8 = switch (builtin.os.tag) {
        .macos => "osx",
        .linux => "linux",
        else => null,
    };

    const arch: ?[]const u8 = switch (builtin.cpu.arch) {
        .powerpcle, .powerpc64le => "ppcle",
        .aarch64, .aarch64_be => "aarch_64",
        .s390x => "s390",
        .x86_64 => "x86_64",
        .x86 => "x86_32",
        else => null,
    };

    const dependency_name = if (builtin.os.tag == .windows)
        "protoc-win64"
    else if (os != null and arch != null)
        try std.mem.concat(b.allocator, u8, &.{ "protoc-", os.?, "-", arch.? })
    else
        @panic("Platform not supported");

    if (b.lazyDependency(dependency_name, .{})) |dep| {
        return dep;
    }

    return null;
}

fn dupeLazyPaths(b: *std.Build, paths: []const std.Build.LazyPath) []std.Build.LazyPath {
    const array = b.allocator.alloc(std.Build.LazyPath, paths.len) catch @panic("OOM");
    for (array, paths) |*dest, source|
        dest.* = source.dupe(b.graph);
    return array;
}

/// 0.17 removed custom `makeFn` build steps (`Step.Tag` is a closed set and
/// `Step` has no function field anymore). This is now a thin wrapper over a
/// `Step.Run` (protoc invocation) chained into a `Step.Fmt`; `.step` points at
/// the fmt step so depending on it runs the whole chain.
pub const RunProtocStep = struct {
    step: *std.Build.Step,

    pub const Options = struct {
        source_files: []const std.Build.LazyPath,
        include_directories: []const std.Build.LazyPath = &.{},
        destination_directory: std.Build.LazyPath,
        /// Optional pre-built protoc-gen-zig artifact. When provided, the
        /// protoc step can be owned by a consumer builder while the generator
        /// stays owned by the zig-protobuf dependency builder.
        generator: ?*std.Build.Step.Compile = null,
        /// Optional pre-built protoc binary. When provided, overrides the
        /// built-in protoc download mechanism.
        protoc: ?std.Build.LazyPath = null,
        /// When true, every generated message preserves unknown fields during
        /// binary decode/encode round trips. Defaults to false.
        preserve_unknown_fields: bool = false,
    };

    pub fn create(
        owner: *std.Build,
        target: std.Build.ResolvedTarget,
        options: Options,
    ) *RunProtocStep {
        const generator = options.generator orelse buildGenerator(owner, .{ .target = target });
        return createWithGenerator(owner, generator, options);
    }

    pub fn createWithGenerator(
        owner: *std.Build,
        generator: *std.Build.Step.Compile,
        options: Options,
    ) *RunProtocStep {
        const b = owner;

        const protoc_bin: ?std.Build.LazyPath = options.protoc orelse blk: {
            const dep = (getProtocDependency(b) catch null) orelse break :blk null;
            break :blk if (builtin.os.tag == .windows)
                dep.path("bin/protoc.exe")
            else
                dep.path("bin/protoc");
        };

        const fmt_step = b.addFmt(.{
            .paths = dupeLazyPaths(b, &.{options.destination_directory}),
        });

        if (protoc_bin) |bin| {
            const run = b.addRunFile(bin);
            run.setName("run protoc");
            run.addPrefixedFileArg("--plugin=protoc-gen-zig=", generator.getEmittedBin());
            if (options.preserve_unknown_fields) {
                run.addPrefixedDirectoryArg("--zig_out=preserve_unknown_fields=true:", options.destination_directory);
            } else {
                run.addPrefixedDirectoryArg("--zig_out=", options.destination_directory);
            }
            for (options.include_directories) |it| run.addPrefixedDirectoryArg("-I", it);
            for (options.source_files) |it| run.addFileArg(it);

            fmt_step.step.dependOn(&run.step);
        }

        const self = b.allocator.create(RunProtocStep) catch @panic("OOM");
        self.* = .{ .step = &fmt_step.step };
        return self;
    }
};

pub const GenOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode = .debug,
};

pub fn buildGenerator(b: *std.Build, opt: GenOptions) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "protoc-gen-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bootstrapped-generator/main.zig"),
            .target = opt.target,
            .optimize = opt.optimize,
        }),
    });

    // 0.17: 与包顶层导出的 "protobuf" 模块同名会 panic;生成器用私有模块。
    const module = b.createModule(.{
        .root_source_file = b.path("src/protobuf.zig"),
    });

    exe.root_module.addImport("protobuf", module);

    return exe;
}
