const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });
    const mk = struct {
        fn mod(bb: *std.Build, root: []const u8, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode) *std.Build.Module {
            return bb.createModule(.{ .root_source_file = bb.path(root), .target = t, .optimize = o, .link_libc = true, .strip = true });
        }
    };
    b.installArtifact(b.addExecutable(.{ .name = "hy", .root_module = mk.mod(b, "src/main.zig", target, optimize) }));
    b.installArtifact(b.addLibrary(.{ .name = "hy", .linkage = .dynamic, .root_module = mk.mod(b, "src/lib.zig", target, optimize) }));
}
