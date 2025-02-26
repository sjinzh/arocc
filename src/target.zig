const std = @import("std");
const LangOpts = @import("LangOpts.zig");
const Type = @import("Type.zig");

pub fn getCharSignedness(target: std.Target) std.builtin.Signedness {
    switch (target.cpu.arch) {
        .aarch64,
        .aarch64_32,
        .aarch64_be,
        .arm,
        .armeb,
        .thumb,
        .thumbeb,
        => return if (target.os.tag.isDarwin() or target.os.tag == .windows) .signed else .unsigned,
        .powerpc, .powerpc64 => return if (target.os.tag.isDarwin()) .signed else .unsigned,
        .powerpc64le,
        .s390x,
        .xcore,
        .arc,
        .msp430,
        => return .unsigned,
        else => return .signed,
    }
}

/// This function returns 1 if function alignment is not observable or settable.
pub fn defaultFunctionAlignment(target: std.Target) u8 {
    return switch (target.cpu.arch) {
        .arm, .armeb => 4,
        .aarch64, .aarch64_32, .aarch64_be => 4,
        .sparc, .sparcel, .sparc64 => 4,
        .riscv64 => 2,
        else => 1,
    };
}

pub fn isTlsSupported(target: std.Target) bool {
    if (target.isDarwin()) {
        var supported = false;
        switch (target.os.tag) {
            .macos => supported = !(target.os.isAtLeast(.macos, .{ .major = 10, .minor = 7 }) orelse false),
            else => {},
        }
        return supported;
    }
    return switch (target.cpu.arch) {
        .tce, .tcele, .bpfel, .bpfeb, .msp430, .nvptx, .nvptx64, .x86, .arm, .armeb, .thumb, .thumbeb => false,
        else => true,
    };
}

pub fn ignoreNonZeroSizedBitfieldTypeAlignment(target: std.Target) bool {
    switch (target.cpu.arch) {
        .avr => return true,
        .arm => {
            if (std.Target.arm.featureSetHas(target.cpu.features, .has_v7)) {
                switch (target.os.tag) {
                    .ios => return true,
                    else => return false,
                }
            }
        },
        else => return false,
    }
    return false;
}

pub fn ignoreZeroSizedBitfieldTypeAlignment(target: std.Target) bool {
    switch (target.cpu.arch) {
        .avr => return true,
        else => return false,
    }
}

pub fn minZeroWidthBitfieldAlignment(target: std.Target) ?u29 {
    switch (target.cpu.arch) {
        .avr => return 8,
        .arm => {
            if (std.Target.arm.featureSetHas(target.cpu.features, .has_v7)) {
                switch (target.os.tag) {
                    .ios => return 32,
                    else => return null,
                }
            } else return null;
        },
        else => return null,
    }
}

pub fn unnamedFieldAffectsAlignment(target: std.Target) bool {
    switch (target.cpu.arch) {
        .aarch64 => {
            if (target.isDarwin() or target.os.tag == .windows) return false;
            return true;
        },
        .armeb => {
            if (std.Target.arm.featureSetHas(target.cpu.features, .has_v7)) {
                if (std.Target.Abi.default(target.cpu.arch, target.os) == .eabi) return true;
            }
        },
        .arm => return true,
        .avr => return true,
        .thumb => {
            if (target.os.tag == .windows) return false;
            return true;
        },
        else => return false,
    }
    return false;
}

pub fn packAllEnums(target: std.Target) bool {
    return switch (target.cpu.arch) {
        .hexagon => true,
        else => false,
    };
}

/// Default alignment (in bytes) for __attribute__((aligned)) when no alignment is specified
pub fn defaultAlignment(target: std.Target) u29 {
    switch (target.cpu.arch) {
        .avr => return 1,
        .arm => if (target.isAndroid() or target.os.tag == .ios) return 16 else return 8,
        .sparc => if (std.Target.sparc.featureSetHas(target.cpu.features, .v9)) return 16 else return 8,
        .mips, .mipsel => switch (target.abi) {
            .none, .gnuabi64 => return 16,
            else => return 8,
        },
        .s390x, .armeb, .thumbeb, .thumb => return 8,
        else => return 16,
    }
}
pub fn systemCompiler(target: std.Target) LangOpts.Compiler {
    // Android is linux but not gcc, so these checks go first
    // the rest for documentation as fn returns .clang
    if (target.isDarwin() or
        target.isAndroid() or
        target.isBSD() or
        target.os.tag == .fuchsia or
        target.os.tag == .solaris or
        target.os.tag == .haiku or
        target.cpu.arch == .hexagon)
    {
        return .clang;
    }
    if (target.os.tag == .uefi) return .msvc;
    // this is before windows to grab WindowsGnu
    if (target.abi.isGnu() or
        target.os.tag == .linux)
    {
        return .gcc;
    }
    if (target.os.tag == .windows) {
        return .msvc;
    }
    if (target.cpu.arch == .avr) return .gcc;
    return .clang;
}

pub fn hasInt128(target: std.Target) bool {
    if (target.cpu.arch == .wasm32) return true;
    return target.cpu.arch.ptrBitWidth() >= 64;
}

test "alignment functions - smoke test" {
    var target: std.Target = undefined;
    const x86 = std.Target.Cpu.Arch.x86_64;
    target.cpu = std.Target.Cpu.baseline(x86);
    target.os = std.Target.Os.Tag.defaultVersionRange(.linux, x86);
    target.abi = std.Target.Abi.default(x86, target.os);

    try std.testing.expect(isTlsSupported(target));
    try std.testing.expect(!ignoreNonZeroSizedBitfieldTypeAlignment(target));
    try std.testing.expect(minZeroWidthBitfieldAlignment(target) == null);
    try std.testing.expect(!unnamedFieldAffectsAlignment(target));
    try std.testing.expect(defaultAlignment(target) == 16);
    try std.testing.expect(!packAllEnums(target));
    try std.testing.expect(systemCompiler(target) == .gcc);

    const arm = std.Target.Cpu.Arch.arm;
    target.cpu = std.Target.Cpu.baseline(arm);
    target.os = std.Target.Os.Tag.defaultVersionRange(.ios, arm);
    target.abi = std.Target.Abi.default(arm, target.os);

    try std.testing.expect(!isTlsSupported(target));
    try std.testing.expect(ignoreNonZeroSizedBitfieldTypeAlignment(target));
    try std.testing.expectEqual(@as(?u29, 32), minZeroWidthBitfieldAlignment(target));
    try std.testing.expect(unnamedFieldAffectsAlignment(target));
    try std.testing.expect(defaultAlignment(target) == 16);
    try std.testing.expect(!packAllEnums(target));
    try std.testing.expect(systemCompiler(target) == .clang);
}

test "target size/align tests" {
    var comp: @import("Compilation.zig") = undefined;

    const x86 = std.Target.Cpu.Arch.x86;
    comp.target.cpu.arch = x86;
    comp.target.cpu.model = &std.Target.x86.cpu.i586;
    comp.target.os = std.Target.Os.Tag.defaultVersionRange(.linux, x86);
    comp.target.abi = std.Target.Abi.gnu;

    const tt: Type = .{
        .specifier = .long_long,
    };

    try std.testing.expectEqual(@as(u64, 8), tt.sizeof(&comp).?);
    try std.testing.expectEqual(@as(u64, 4), tt.alignof(&comp));

    const arm = std.Target.Cpu.Arch.arm;
    comp.target.cpu = std.Target.Cpu.Model.toCpu(&std.Target.arm.cpu.cortex_r4, arm);
    comp.target.os = std.Target.Os.Tag.defaultVersionRange(.ios, arm);
    comp.target.abi = std.Target.Abi.none;

    const ct: Type = .{
        .specifier = .char,
    };

    try std.testing.expectEqual(true, std.Target.arm.featureSetHas(comp.target.cpu.features, .has_v7));
    try std.testing.expectEqual(@as(u64, 1), ct.sizeof(&comp).?);
    try std.testing.expectEqual(@as(u64, 1), ct.alignof(&comp));
    try std.testing.expectEqual(true, ignoreNonZeroSizedBitfieldTypeAlignment(comp.target));
}
