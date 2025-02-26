const std = @import("std");
const Tree = @import("Tree.zig");
const TokenIndex = Tree.TokenIndex;
const NodeIndex = Tree.NodeIndex;
const Parser = @import("Parser.zig");
const Compilation = @import("Compilation.zig");
const Attribute = @import("Attribute.zig");
const StringInterner = @import("StringInterner.zig");
const StringId = StringInterner.StringId;
const CType = @import("zig").CType;
const target = @import("target.zig");
const LangOpts = @import("LangOpts.zig");

const Type = @This();

pub const Qualifiers = packed struct {
    @"const": bool = false,
    atomic: bool = false,
    @"volatile": bool = false,
    restrict: bool = false,

    // for function parameters only, stored here since it fits in the padding
    register: bool = false,

    pub fn any(quals: Qualifiers) bool {
        return quals.@"const" or quals.restrict or quals.@"volatile" or quals.atomic;
    }

    pub fn dump(quals: Qualifiers, w: anytype) !void {
        if (quals.@"const") try w.writeAll("const ");
        if (quals.atomic) try w.writeAll("_Atomic ");
        if (quals.@"volatile") try w.writeAll("volatile ");
        if (quals.restrict) try w.writeAll("restrict ");
        if (quals.register) try w.writeAll("register ");
    }

    /// Merge the const/volatile qualifiers, used by type resolution
    /// of the conditional operator
    pub fn mergeCV(a: Qualifiers, b: Qualifiers) Qualifiers {
        return .{
            .@"const" = a.@"const" or b.@"const",
            .@"volatile" = a.@"volatile" or b.@"volatile",
        };
    }

    /// Merge all qualifiers, used by typeof()
    fn mergeAll(a: Qualifiers, b: Qualifiers) Qualifiers {
        return .{
            .@"const" = a.@"const" or b.@"const",
            .atomic = a.atomic or b.atomic,
            .@"volatile" = a.@"volatile" or b.@"volatile",
            .restrict = a.restrict or b.restrict,
            .register = a.register or b.register,
        };
    }

    /// Checks if a has all the qualifiers of b
    pub fn hasQuals(a: Qualifiers, b: Qualifiers) bool {
        if (b.@"const" and !a.@"const") return false;
        if (b.@"volatile" and !a.@"volatile") return false;
        if (b.atomic and !a.atomic) return false;
        return true;
    }

    /// register is a storage class and not actually a qualifier
    /// so it is not preserved by typeof()
    pub fn inheritFromTypeof(quals: Qualifiers) Qualifiers {
        var res = quals;
        res.register = false;
        return res;
    }

    pub const Builder = struct {
        @"const": ?TokenIndex = null,
        atomic: ?TokenIndex = null,
        @"volatile": ?TokenIndex = null,
        restrict: ?TokenIndex = null,

        pub fn finish(b: Qualifiers.Builder, p: *Parser, ty: *Type) !void {
            if (ty.specifier != .pointer and b.restrict != null) {
                try p.errStr(.restrict_non_pointer, b.restrict.?, try p.typeStr(ty.*));
            }
            if (b.atomic) |some| {
                if (ty.isArray()) try p.errStr(.atomic_array, some, try p.typeStr(ty.*));
                if (ty.isFunc()) try p.errStr(.atomic_func, some, try p.typeStr(ty.*));
                if (ty.hasIncompleteSize()) try p.errStr(.atomic_incomplete, some, try p.typeStr(ty.*));
            }

            if (b.@"const" != null) ty.qual.@"const" = true;
            if (b.atomic != null) ty.qual.atomic = true;
            if (b.@"volatile" != null) ty.qual.@"volatile" = true;
            if (b.restrict != null) ty.qual.restrict = true;
        }
    };
};

// TODO improve memory usage
pub const Func = struct {
    return_type: Type,
    params: []Param,

    pub const Param = struct {
        ty: Type,
        name: StringId,
        name_tok: TokenIndex,
    };
};

pub const Array = struct {
    len: u64,
    elem: Type,
};

pub const Expr = struct {
    node: NodeIndex,
    ty: Type,
};

pub const Attributed = struct {
    attributes: []Attribute,
    base: Type,

    pub fn create(allocator: std.mem.Allocator, base: Type, existing_attributes: []const Attribute, attributes: []const Attribute) !*Attributed {
        var attributed_type = try allocator.create(Attributed);
        errdefer allocator.destroy(attributed_type);

        var all_attrs = try allocator.alloc(Attribute, existing_attributes.len + attributes.len);
        std.mem.copy(Attribute, all_attrs, existing_attributes);
        std.mem.copy(Attribute, all_attrs[existing_attributes.len..], attributes);

        attributed_type.* = .{
            .attributes = all_attrs,
            .base = base,
        };
        return attributed_type;
    }
};

// TODO improve memory usage
pub const Enum = struct {
    fields: []Field,
    tag_ty: Type,
    name: StringId,
    fixed: bool,

    pub const Field = struct {
        ty: Type,
        name: StringId,
        name_tok: TokenIndex,
        node: NodeIndex,
    };

    pub fn isIncomplete(e: Enum) bool {
        return e.fields.len == std.math.maxInt(usize);
    }

    pub fn create(allocator: std.mem.Allocator, name: StringId, fixed_ty: ?Type) !*Enum {
        var e = try allocator.create(Enum);
        e.name = name;
        e.fields.len = std.math.maxInt(usize);
        if (fixed_ty) |some| e.tag_ty = some;
        e.fixed = fixed_ty != null;
        return e;
    }
};

// might not need all 4 of these when finished,
// but currently it helps having all 4 when diff-ing
// the rust code.
pub const TypeLayout = struct {
    /// The size of the type in bits.
    ///
    /// This is the value returned by `sizeof` and C and `std::mem::size_of` in Rust
    /// (but in bits instead of bytes). This is a multiple of `pointer_alignment_bits`.
    size_bits: u64,
    /// The alignment of the type, in bits, when used as a field in a record.
    ///
    /// This is usually the value returned by `_Alignof` in C, but there are some edge
    /// cases in GCC where `_Alignof` returns a smaller value.
    field_alignment_bits: u32,
    /// The alignment, in bits, of valid pointers to this type.
    ///
    /// This is the value returned by `std::mem::align_of` in Rust
    /// (but in bits instead of bytes). `size_bits` is a multiple of this value.
    pointer_alignment_bits: u32,
    /// The required alignment of the type in bits.
    ///
    /// This value is only used by MSVC targets. It is 8 on all other
    /// targets. On MSVC targets, this value restricts the effects of `#pragma pack` except
    /// in some cases involving bit-fields.
    required_alignment_bits: u32,
};

pub const FieldLayout = struct {
    /// `offset_bits` and `size_bits` should both be INVALID if and only if the field
    /// is an unnamed bitfield. There is no way to reference an unnamed bitfield in C, so
    /// there should be no way to observe these values. If it is used, this value will
    /// maximize the chance that a safety-checked overflow will occur.
    const INVALID = std.math.maxInt(u64);

    /// The offset of the field, in bits, from the start of the struct.
    offset_bits: u64 = INVALID,
    /// The size, in bits, of the field.
    ///
    /// For bit-fields, this is the width of the field.
    size_bits: u64 = INVALID,

    pub fn isUnnamed(self: FieldLayout) bool {
        return self.offset_bits == INVALID and self.size_bits == INVALID;
    }
};

// TODO improve memory usage
pub const Record = struct {
    fields: []Field,
    type_layout: TypeLayout,
    /// If this is null, none of the fields have attributes
    /// Otherwise, it's a pointer to N items (where N == number of fields)
    /// and the item at index i is the attributes for the field at index i
    field_attributes: ?[*][]const Attribute,
    name: StringId,

    pub const Field = struct {
        ty: Type,
        name: StringId,
        /// zero for anonymous fields
        name_tok: TokenIndex = 0,
        bit_width: ?u32 = null,
        layout: FieldLayout = .{
            .offset_bits = 0,
            .size_bits = 0,
        },

        pub fn isNamed(f: *const Field) bool {
            return f.name_tok != 0;
        }

        pub fn isAnonymousRecord(f: Field) bool {
            return !f.isNamed() and f.ty.isRecord();
        }

        /// false for bitfields
        pub fn isRegularField(f: *const Field) bool {
            return f.bit_width == null;
        }

        /// bit width as specified in the C source. Asserts that `f` is a bitfield.
        pub fn specifiedBitWidth(f: *const Field) u32 {
            return f.bit_width.?;
        }
    };

    pub fn isIncomplete(r: Record) bool {
        return r.fields.len == std.math.maxInt(usize);
    }

    pub fn create(allocator: std.mem.Allocator, name: StringId) !*Record {
        var r = try allocator.create(Record);
        r.name = name;
        r.fields.len = std.math.maxInt(usize);
        r.field_attributes = null;
        r.type_layout = .{
            .size_bits = 8,
            .field_alignment_bits = 8,
            .pointer_alignment_bits = 8,
            .required_alignment_bits = 8,
        };
        return r;
    }
};

pub const Specifier = enum {
    /// A NaN-like poison value
    invalid,

    void,
    bool,

    // integers
    char,
    schar,
    uchar,
    short,
    ushort,
    int,
    uint,
    long,
    ulong,
    long_long,
    ulong_long,
    int128,
    uint128,
    complex_char,
    complex_schar,
    complex_uchar,
    complex_short,
    complex_ushort,
    complex_int,
    complex_uint,
    complex_long,
    complex_ulong,
    complex_long_long,
    complex_ulong_long,
    complex_int128,
    complex_uint128,

    // data.int
    bit_int,
    complex_bit_int,

    // floating point numbers
    fp16,
    float,
    double,
    long_double,
    float80,
    float128,
    complex_fp16,
    complex_float,
    complex_double,
    complex_long_double,
    complex_float80,
    complex_float128,

    // data.sub_type
    pointer,
    unspecified_variable_len_array,
    decayed_unspecified_variable_len_array,
    // data.func
    /// int foo(int bar, char baz) and int (void)
    func,
    /// int foo(int bar, char baz, ...)
    var_args_func,
    /// int foo(bar, baz) and int foo()
    /// is also var args, but we can give warnings about incorrect amounts of parameters
    old_style_func,

    // data.array
    array,
    decayed_array,
    static_array,
    decayed_static_array,
    incomplete_array,
    decayed_incomplete_array,
    vector,
    // data.expr
    variable_len_array,
    decayed_variable_len_array,

    // data.record
    @"struct",
    @"union",

    // data.enum
    @"enum",

    /// typeof(type-name)
    typeof_type,
    /// decayed array created with typeof(type-name)
    decayed_typeof_type,

    /// typeof(expression)
    typeof_expr,
    /// decayed array created with typeof(expression)
    decayed_typeof_expr,

    /// data.attributed
    attributed,

    /// special type used to implement __builtin_va_start
    special_va_start,

    /// C23 nullptr_t
    nullptr_t,
};

/// All fields of Type except data may be mutated
data: union {
    sub_type: *Type,
    func: *Func,
    array: *Array,
    expr: *Expr,
    @"enum": *Enum,
    record: *Record,
    attributed: *Attributed,
    none: void,
    int: struct {
        bits: u8,
        signedness: std.builtin.Signedness,
    },
} = .{ .none = {} },
specifier: Specifier,
qual: Qualifiers = .{},

pub const int = Type{ .specifier = .int };
pub const invalid = Type{ .specifier = .invalid };

/// Determine if type matches the given specifier, recursing into typeof
/// types if necessary.
pub fn is(ty: Type, specifier: Specifier) bool {
    std.debug.assert(specifier != .typeof_type and specifier != .typeof_expr);
    return ty.get(specifier) != null;
}

pub fn withAttributes(self: Type, allocator: std.mem.Allocator, attributes: []const Attribute) !Type {
    if (attributes.len == 0) return self;
    const attributed_type = try Type.Attributed.create(allocator, self, self.getAttributes(), attributes);
    return Type{ .specifier = .attributed, .data = .{ .attributed = attributed_type } };
}

pub fn isCallable(ty: Type) ?Type {
    return switch (ty.specifier) {
        .func, .var_args_func, .old_style_func => ty,
        .pointer => if (ty.data.sub_type.isFunc()) ty.data.sub_type.* else null,
        .typeof_type => ty.data.sub_type.isCallable(),
        .typeof_expr => ty.data.expr.ty.isCallable(),
        .attributed => ty.data.attributed.base.isCallable(),
        else => null,
    };
}

pub fn isFunc(ty: Type) bool {
    return switch (ty.specifier) {
        .func, .var_args_func, .old_style_func => true,
        .typeof_type => ty.data.sub_type.isFunc(),
        .typeof_expr => ty.data.expr.ty.isFunc(),
        .attributed => ty.data.attributed.base.isFunc(),
        else => false,
    };
}

pub fn isArray(ty: Type) bool {
    return switch (ty.specifier) {
        .array, .static_array, .incomplete_array, .variable_len_array, .unspecified_variable_len_array => true,
        .typeof_type => ty.data.sub_type.isArray(),
        .typeof_expr => ty.data.expr.ty.isArray(),
        .attributed => ty.data.attributed.base.isArray(),
        else => false,
    };
}

pub fn isScalar(ty: Type) bool {
    return ty.isInt() or ty.isScalarNonInt();
}

/// To avoid calling isInt() twice for allowable loop/if controlling expressions
pub fn isScalarNonInt(ty: Type) bool {
    return ty.isFloat() or ty.isPtr() or ty.is(.nullptr_t);
}

pub fn isDecayed(ty: Type) bool {
    const decayed = switch (ty.specifier) {
        .decayed_array,
        .decayed_static_array,
        .decayed_incomplete_array,
        .decayed_variable_len_array,
        .decayed_unspecified_variable_len_array,
        .decayed_typeof_type,
        .decayed_typeof_expr,
        => true,
        else => false,
    };
    std.debug.assert(decayed or !std.mem.startsWith(u8, @tagName(ty.specifier), "decayed"));
    return decayed;
}

pub fn isPtr(ty: Type) bool {
    return switch (ty.specifier) {
        .pointer,
        .decayed_array,
        .decayed_static_array,
        .decayed_incomplete_array,
        .decayed_variable_len_array,
        .decayed_unspecified_variable_len_array,
        .decayed_typeof_type,
        .decayed_typeof_expr,
        => true,
        .typeof_type => ty.data.sub_type.isPtr(),
        .typeof_expr => ty.data.expr.ty.isPtr(),
        .attributed => ty.data.attributed.base.isPtr(),
        else => false,
    };
}

pub fn isInt(ty: Type) bool {
    return switch (ty.specifier) {
        // zig fmt: off
        .@"enum", .bool, .char, .schar, .uchar, .short, .ushort, .int, .uint, .long, .ulong,
        .long_long, .ulong_long, .int128, .uint128, .complex_char, .complex_schar, .complex_uchar,
        .complex_short, .complex_ushort, .complex_int, .complex_uint, .complex_long, .complex_ulong,
        .complex_long_long, .complex_ulong_long, .complex_int128, .complex_uint128,
        .bit_int, .complex_bit_int => true,
        // zig fmt: on
        .typeof_type => ty.data.sub_type.isInt(),
        .typeof_expr => ty.data.expr.ty.isInt(),
        .attributed => ty.data.attributed.base.isInt(),
        else => false,
    };
}

pub fn isFloat(ty: Type) bool {
    return switch (ty.specifier) {
        // zig fmt: off
        .float, .double, .long_double, .complex_float, .complex_double, .complex_long_double,
        .fp16, .float80, .float128, .complex_fp16, .complex_float80, .complex_float128 => true,
        // zig fmt: on
        .typeof_type => ty.data.sub_type.isFloat(),
        .typeof_expr => ty.data.expr.ty.isFloat(),
        .attributed => ty.data.attributed.base.isFloat(),
        else => false,
    };
}

pub fn isReal(ty: Type) bool {
    return switch (ty.specifier) {
        // zig fmt: off
        .complex_float, .complex_double, .complex_long_double, .complex_fp16, .complex_float80,
        .complex_float128, .complex_char, .complex_schar, .complex_uchar, .complex_short,
        .complex_ushort, .complex_int, .complex_uint, .complex_long, .complex_ulong,
        .complex_long_long, .complex_ulong_long, .complex_int128, .complex_uint128,
        .complex_bit_int => false,
        // zig fmt: on
        .typeof_type => ty.data.sub_type.isReal(),
        .typeof_expr => ty.data.expr.ty.isReal(),
        .attributed => ty.data.attributed.base.isReal(),
        else => true,
    };
}

pub fn isVoidStar(ty: Type) bool {
    return switch (ty.specifier) {
        .pointer => ty.data.sub_type.specifier == .void,
        .typeof_type => ty.data.sub_type.isVoidStar(),
        .typeof_expr => ty.data.expr.ty.isVoidStar(),
        .attributed => ty.data.attributed.base.isVoidStar(),
        else => false,
    };
}

pub fn isTypeof(ty: Type) bool {
    return switch (ty.specifier) {
        .typeof_type, .typeof_expr, .decayed_typeof_type, .decayed_typeof_expr => true,
        else => false,
    };
}

pub fn isConst(ty: Type) bool {
    return switch (ty.specifier) {
        .typeof_type, .decayed_typeof_type => ty.qual.@"const" or ty.data.sub_type.isConst(),
        .typeof_expr, .decayed_typeof_expr => ty.qual.@"const" or ty.data.expr.ty.isConst(),
        .attributed => ty.data.attributed.base.isConst(),
        else => ty.qual.@"const",
    };
}

pub fn isUnsignedInt(ty: Type, comp: *const Compilation) bool {
    return switch (ty.specifier) {
        // zig fmt: off
        .char, .complex_char => return target.getCharSignedness(comp.target) == .unsigned,
        .uchar, .ushort, .uint, .ulong, .ulong_long, .bool, .complex_uchar, .complex_ushort,
        .complex_uint, .complex_ulong, .complex_ulong_long, .complex_uint128 => true,
        // zig fmt: on
        .bit_int, .complex_bit_int => return ty.data.int.signedness == .unsigned,
        .typeof_type => ty.data.sub_type.isUnsignedInt(comp),
        .typeof_expr => ty.data.expr.ty.isUnsignedInt(comp),
        .attributed => ty.data.attributed.base.isUnsignedInt(comp),
        else => false,
    };
}

pub fn isEnumOrRecord(ty: Type) bool {
    return switch (ty.specifier) {
        .@"enum", .@"struct", .@"union" => true,
        .typeof_type => ty.data.sub_type.isEnumOrRecord(),
        .typeof_expr => ty.data.expr.ty.isEnumOrRecord(),
        .attributed => ty.data.attributed.base.isEnumOrRecord(),
        else => false,
    };
}

pub fn isRecord(ty: Type) bool {
    return switch (ty.specifier) {
        .@"struct", .@"union" => true,
        .typeof_type => ty.data.sub_type.isRecord(),
        .typeof_expr => ty.data.expr.ty.isRecord(),
        .attributed => ty.data.attributed.base.isRecord(),
        else => false,
    };
}

pub fn isAnonymousRecord(ty: Type, comp: *const Compilation) bool {
    return switch (ty.specifier) {
        // anonymous records can be recognized by their names which are in
        // the format "(anonymous TAG at path:line:col)".
        .@"struct", .@"union" => {
            const mapper = comp.string_interner.getSlowTypeMapper();
            return mapper.lookup(ty.data.record.name)[0] == '(';
        },
        .typeof_type => ty.data.sub_type.isAnonymousRecord(comp),
        .typeof_expr => ty.data.expr.ty.isAnonymousRecord(comp),
        .attributed => ty.data.attributed.base.isAnonymousRecord(comp),
        else => false,
    };
}

pub fn elemType(ty: Type) Type {
    return switch (ty.specifier) {
        .pointer, .unspecified_variable_len_array, .decayed_unspecified_variable_len_array => ty.data.sub_type.*,
        .array, .static_array, .incomplete_array, .decayed_array, .decayed_static_array, .decayed_incomplete_array, .vector => ty.data.array.elem,
        .variable_len_array, .decayed_variable_len_array => ty.data.expr.ty,
        .typeof_type, .decayed_typeof_type, .typeof_expr, .decayed_typeof_expr => {
            const unwrapped = ty.canonicalize(.preserve_quals);
            var elem = unwrapped.elemType();
            elem.qual = elem.qual.mergeAll(unwrapped.qual);
            return elem;
        },
        .attributed => ty.data.attributed.base,
        .invalid => Type.invalid,
        else => unreachable,
    };
}

pub fn returnType(ty: Type) Type {
    return switch (ty.specifier) {
        .func, .var_args_func, .old_style_func => ty.data.func.return_type,
        .typeof_type, .decayed_typeof_type => ty.data.sub_type.returnType(),
        .typeof_expr, .decayed_typeof_expr => ty.data.expr.ty.returnType(),
        .attributed => ty.data.attributed.base.returnType(),
        .invalid => Type.invalid,
        else => unreachable,
    };
}

pub fn params(ty: Type) []Func.Param {
    return switch (ty.specifier) {
        .func, .var_args_func, .old_style_func => ty.data.func.params,
        .typeof_type, .decayed_typeof_type => ty.data.sub_type.params(),
        .typeof_expr, .decayed_typeof_expr => ty.data.expr.ty.params(),
        .attributed => ty.data.attributed.base.params(),
        .invalid => &.{},
        else => unreachable,
    };
}

pub fn arrayLen(ty: Type) ?u64 {
    return switch (ty.specifier) {
        .array, .static_array, .decayed_array, .decayed_static_array => ty.data.array.len,
        .typeof_type, .decayed_typeof_type => ty.data.sub_type.arrayLen(),
        .typeof_expr, .decayed_typeof_expr => ty.data.expr.ty.arrayLen(),
        .attributed => ty.data.attributed.base.arrayLen(),
        else => null,
    };
}

pub fn anyQual(ty: Type) bool {
    return switch (ty.specifier) {
        .typeof_type => ty.qual.any() or ty.data.sub_type.anyQual(),
        .typeof_expr => ty.qual.any() or ty.data.expr.ty.anyQual(),
        else => ty.qual.any(),
    };
}

pub fn getAttributes(ty: Type) []const Attribute {
    return switch (ty.specifier) {
        .attributed => ty.data.attributed.attributes,
        .typeof_type, .decayed_typeof_type => ty.data.sub_type.getAttributes(),
        .typeof_expr, .decayed_typeof_expr => ty.data.expr.ty.getAttributes(),
        else => &.{},
    };
}

pub fn getRecord(ty: Type) ?*const Type.Record {
    return switch (ty.specifier) {
        .attributed => ty.data.attributed.base.getRecord(),
        .typeof_type, .decayed_typeof_type => ty.data.sub_type.getRecord(),
        .typeof_expr, .decayed_typeof_expr => ty.data.expr.ty.getRecord(),
        .@"struct", .@"union" => ty.data.record,
        else => null,
    };
}

pub fn integerPromotion(ty: Type, comp: *Compilation) Type {
    var specifier = ty.specifier;
    if (specifier == .@"enum") {
        if (ty.hasIncompleteSize()) return .{ .specifier = .int };
        specifier = ty.data.@"enum".tag_ty.specifier;
    }
    return .{
        .specifier = switch (specifier) {
            // zig fmt: off
            .bool, .char, .schar, .uchar, .short => .int,
            .ushort => if (ty.sizeof(comp).? == sizeof(.{ .specifier = .int }, comp)) Specifier.uint else .int,
            .int, .uint, .long, .ulong, .long_long, .ulong_long, .int128, .uint128, .complex_char,
            .complex_schar, .complex_uchar, .complex_short, .complex_ushort, .complex_int,
            .complex_uint, .complex_long, .complex_ulong, .complex_long_long, .complex_ulong_long,
            .complex_int128, .complex_uint128, .bit_int, .complex_bit_int => specifier,
            // zig fmt: on
            .typeof_type => return ty.data.sub_type.integerPromotion(comp),
            .typeof_expr => return ty.data.expr.ty.integerPromotion(comp),
            .attributed => return ty.data.attributed.base.integerPromotion(comp),
            .invalid => .invalid,
            else => unreachable, // not an integer type
        },
    };
}

pub fn hasIncompleteSize(ty: Type) bool {
    return switch (ty.specifier) {
        .void, .incomplete_array, .invalid => true,
        .@"enum" => ty.data.@"enum".isIncomplete() and !ty.data.@"enum".fixed,
        .@"struct", .@"union" => ty.data.record.isIncomplete(),
        .array, .static_array => ty.data.array.elem.hasIncompleteSize(),
        .typeof_type => ty.data.sub_type.hasIncompleteSize(),
        .typeof_expr => ty.data.expr.ty.hasIncompleteSize(),
        .attributed => ty.data.attributed.base.hasIncompleteSize(),
        else => false,
    };
}

pub fn hasUnboundVLA(ty: Type) bool {
    var cur = ty;
    while (true) {
        switch (cur.specifier) {
            .unspecified_variable_len_array,
            .decayed_unspecified_variable_len_array,
            => return true,
            .array,
            .static_array,
            .incomplete_array,
            .variable_len_array,
            .decayed_array,
            .decayed_static_array,
            .decayed_incomplete_array,
            .decayed_variable_len_array,
            => cur = cur.elemType(),
            .typeof_type, .decayed_typeof_type => cur = cur.data.sub_type.*,
            .typeof_expr, .decayed_typeof_expr => cur = cur.data.expr.ty,
            .attributed => cur = cur.data.attributed.base,
            else => return false,
        }
    }
}

pub fn hasField(ty: Type, name: StringId) bool {
    switch (ty.specifier) {
        .@"struct" => {
            std.debug.assert(!ty.data.record.isIncomplete());
            for (ty.data.record.fields) |f| {
                if (f.isAnonymousRecord() and f.ty.hasField(name)) return true;
                if (name == f.name) return true;
            }
        },
        .@"union" => {
            std.debug.assert(!ty.data.record.isIncomplete());
            for (ty.data.record.fields) |f| {
                if (f.isAnonymousRecord() and f.ty.hasField(name)) return true;
                if (name == f.name) return true;
            }
        },
        .typeof_type => return ty.data.sub_type.hasField(name),
        .typeof_expr => return ty.data.expr.ty.hasField(name),
        .attributed => return ty.data.attributed.base.hasField(name),
        .invalid => return false,
        else => unreachable,
    }
    return false;
}

pub fn minInt(ty: Type, comp: *const Compilation) i64 {
    std.debug.assert(ty.isInt());
    if (ty.isUnsignedInt(comp)) return 0;
    return switch (ty.sizeof(comp).?) {
        1 => std.math.minInt(i8),
        2 => std.math.minInt(i16),
        4 => std.math.minInt(i32),
        8 => std.math.minInt(i64),
        else => unreachable,
    };
}

pub fn maxInt(ty: Type, comp: *const Compilation) u64 {
    std.debug.assert(ty.isInt());
    return switch (ty.sizeof(comp).?) {
        1 => if (ty.isUnsignedInt(comp)) @as(u64, std.math.maxInt(u8)) else std.math.maxInt(i8),
        2 => if (ty.isUnsignedInt(comp)) @as(u64, std.math.maxInt(u16)) else std.math.maxInt(i16),
        4 => if (ty.isUnsignedInt(comp)) @as(u64, std.math.maxInt(u32)) else std.math.maxInt(i32),
        8 => if (ty.isUnsignedInt(comp)) @as(u64, std.math.maxInt(u64)) else std.math.maxInt(i64),
        else => unreachable,
    };
}

const TypeSizeOrder = enum {
    lt,
    gt,
    eq,
    indeterminate,
};

pub fn sizeCompare(a: Type, b: Type, comp: *Compilation) TypeSizeOrder {
    const a_size = a.sizeof(comp) orelse return .indeterminate;
    const b_size = b.sizeof(comp) orelse return .indeterminate;
    return switch (std.math.order(a_size, b_size)) {
        .lt => .lt,
        .gt => .gt,
        .eq => .eq,
    };
}

/// Size of type as reported by sizeof
pub fn sizeof(ty: Type, comp: *const Compilation) ?u64 {
    return switch (ty.specifier) {
        .variable_len_array, .unspecified_variable_len_array => return null,
        .incomplete_array => return if (comp.langopts.emulate == .msvc) @as(?u64, 0) else null,
        .func, .var_args_func, .old_style_func, .void, .bool => 1,
        .char, .schar, .uchar => 1,
        .short => @divExact(CType.sizeInBits(.short, comp.target), 8),
        .ushort => @divExact(CType.sizeInBits(.ushort, comp.target), 8),
        .int => @divExact(CType.sizeInBits(.int, comp.target), 8),
        .uint => @divExact(CType.sizeInBits(.uint, comp.target), 8),
        .long => @divExact(CType.sizeInBits(.long, comp.target), 8),
        .ulong => @divExact(CType.sizeInBits(.ulong, comp.target), 8),
        .long_long => @divExact(CType.sizeInBits(.longlong, comp.target), 8),
        .ulong_long => @divExact(CType.sizeInBits(.ulonglong, comp.target), 8),
        .long_double => @divExact(CType.sizeInBits(.longdouble, comp.target), 8),
        .int128, .uint128 => 16,
        .fp16 => 2,
        .float => @divExact(CType.sizeInBits(.float, comp.target), 8),
        .double => @divExact(CType.sizeInBits(.double, comp.target), 8),
        .float80 => 16,
        .float128 => 16,
        .bit_int => {
            return std.mem.alignForwardGeneric(u64, (ty.data.int.bits + 7) / 8, ty.alignof(comp));
        },
        // zig fmt: off
        .complex_char, .complex_schar, .complex_uchar, .complex_short, .complex_ushort, .complex_int,
        .complex_uint, .complex_long, .complex_ulong, .complex_long_long, .complex_ulong_long,
        .complex_int128, .complex_uint128, .complex_fp16, .complex_float, .complex_double,
        .complex_long_double, .complex_float80, .complex_float128, .complex_bit_int,
        => return 2 * ty.makeReal().sizeof(comp).?,
        // zig fmt: on
        .pointer,
        .decayed_array,
        .decayed_static_array,
        .decayed_incomplete_array,
        .decayed_variable_len_array,
        .decayed_unspecified_variable_len_array,
        .decayed_typeof_type,
        .decayed_typeof_expr,
        .static_array,
        .nullptr_t,
        => CType.ptrBitWidth(comp.target) >> 3,
        .array, .vector => {
            const size = ty.data.array.elem.sizeof(comp) orelse return null;
            const arr_size = size * ty.data.array.len;
            if (comp.langopts.emulate == .msvc) {
                // msvc ignores array type alignment.
                // Since the size might not be a multiple of the field
                // alignment, the address of the second element might not be properly aligned
                // for the field alignment. A flexible array has size 0. See test case 0018.
                return arr_size;
            } else {
                return std.mem.alignForwardGeneric(u64, arr_size, ty.alignof(comp));
            }
        },
        .@"struct", .@"union" => if (ty.data.record.isIncomplete()) null else @as(u64, ty.data.record.type_layout.size_bits / 8),
        .@"enum" => if (ty.data.@"enum".isIncomplete() and !ty.data.@"enum".fixed) null else ty.data.@"enum".tag_ty.sizeof(comp),
        .typeof_type => ty.data.sub_type.sizeof(comp),
        .typeof_expr => ty.data.expr.ty.sizeof(comp),
        .attributed => ty.data.attributed.base.sizeof(comp),
        .invalid => return null,
        else => unreachable,
    };
}

pub fn bitSizeof(ty: Type, comp: *const Compilation) ?u64 {
    return switch (ty.specifier) {
        .bool => if (comp.langopts.emulate == .msvc) @as(u64, 8) else 1,
        .typeof_type, .decayed_typeof_type => ty.data.sub_type.bitSizeof(comp),
        .typeof_expr, .decayed_typeof_expr => ty.data.expr.ty.bitSizeof(comp),
        .attributed => ty.data.attributed.base.bitSizeof(comp),
        .bit_int => return ty.data.int.bits,
        .long_double => CType.sizeInBits(.longdouble, comp.target),
        .float80 => return 80,
        else => 8 * (ty.sizeof(comp) orelse return null),
    };
}

pub fn alignable(ty: Type) bool {
    return ty.isArray() or !ty.hasIncompleteSize() or ty.is(.void);
}

/// Get the alignment of a type
pub fn alignof(ty: Type, comp: *const Compilation) u29 {
    // don't return the attribute for records
    // layout has already accounted for requested alignment
    if (ty.requestedAlignment(comp)) |requested| {
        // gcc does not respect alignment on enums
        if (ty.get(.@"enum")) |ty_enum| {
            if (comp.langopts.emulate == .gcc) {
                return ty_enum.alignof(comp);
            }
        } else if (ty.getRecord()) |rec| {
            if (ty.hasIncompleteSize()) return 0;
            const computed = @intCast(u29, @divExact(rec.type_layout.field_alignment_bits, 8));
            return std.math.max(requested, computed);
        } else if (comp.langopts.emulate == .msvc) {
            const type_align = ty.data.attributed.base.alignof(comp);
            return std.math.max(requested, type_align);
        }
        return requested;
    }

    return switch (ty.specifier) {
        .invalid, .special_va_start => unreachable,

        .variable_len_array,
        .incomplete_array,
        .unspecified_variable_len_array,
        .array,
        .vector,
        => ty.elemType().alignof(comp),
        .func, .var_args_func, .old_style_func => target.defaultFunctionAlignment(comp.target),
        .char, .schar, .uchar, .void, .bool => 1,

        // zig fmt: off
        .complex_char, .complex_schar, .complex_uchar, .complex_short, .complex_ushort, .complex_int,
        .complex_uint, .complex_long, .complex_ulong, .complex_long_long, .complex_ulong_long,
        .complex_int128, .complex_uint128, .complex_fp16, .complex_float, .complex_double,
        .complex_long_double, .complex_float80, .complex_float128, .complex_bit_int,
        => return ty.makeReal().alignof(comp),
        // zig fmt: on

        .short => CType.short.alignment(comp.target),
        .ushort => CType.ushort.alignment(comp.target),
        .int => CType.int.alignment(comp.target),
        .uint => CType.uint.alignment(comp.target),

        .long => CType.long.alignment(comp.target),
        .ulong => CType.ulong.alignment(comp.target),
        .long_long => CType.longlong.alignment(comp.target),
        .ulong_long => CType.ulonglong.alignment(comp.target),

        .bit_int => @min(
            std.math.ceilPowerOfTwoPromote(u16, (ty.data.int.bits + 7) / 8),
            comp.target.maxIntAlignment(),
        ),

        .float => CType.float.alignment(comp.target),
        .double => CType.double.alignment(comp.target),
        .long_double => CType.longdouble.alignment(comp.target),

        .int128, .uint128 => if (comp.target.cpu.arch == .s390x and comp.target.os.tag == .linux and comp.target.isGnu()) 8 else 16,
        .fp16 => 2,

        .float80, .float128 => 16,
        .pointer,
        .decayed_array,
        .decayed_static_array,
        .decayed_incomplete_array,
        .decayed_variable_len_array,
        .decayed_unspecified_variable_len_array,
        .static_array,
        .nullptr_t,
        => switch (comp.target.cpu.arch) {
            .avr => 1,
            else => CType.ptrBitWidth(comp.target) >> 3,
        },
        .@"struct", .@"union" => if (ty.data.record.isIncomplete()) 0 else @intCast(u29, ty.data.record.type_layout.field_alignment_bits / 8),
        .@"enum" => if (ty.data.@"enum".isIncomplete() and !ty.data.@"enum".fixed) 0 else ty.data.@"enum".tag_ty.alignof(comp),
        .typeof_type, .decayed_typeof_type => ty.data.sub_type.alignof(comp),
        .typeof_expr, .decayed_typeof_expr => ty.data.expr.ty.alignof(comp),
        .attributed => ty.data.attributed.base.alignof(comp),
    };
}

/// Canonicalize a possibly-typeof() type. If the type is not a typeof() type, simply
/// return it. Otherwise, determine the actual qualified type.
/// The `qual_handling` parameter can be used to return the full set of qualifiers
/// added by typeof() operations, which is useful when determining the elemType of
/// arrays and pointers.
pub fn canonicalize(ty: Type, qual_handling: enum { standard, preserve_quals }) Type {
    var cur = ty;
    if (cur.specifier == .attributed) cur = cur.data.attributed.base;
    if (!cur.isTypeof()) return cur;

    var qual = cur.qual;
    while (true) {
        switch (cur.specifier) {
            .typeof_type => cur = cur.data.sub_type.*,
            .typeof_expr => cur = cur.data.expr.ty,
            .decayed_typeof_type => {
                cur = cur.data.sub_type.*;
                cur.decayArray();
            },
            .decayed_typeof_expr => {
                cur = cur.data.expr.ty;
                cur.decayArray();
            },
            else => break,
        }
        qual = qual.mergeAll(cur.qual);
    }
    if ((cur.isArray() or cur.isPtr()) and qual_handling == .standard) {
        cur.qual = .{};
    } else {
        cur.qual = qual;
    }
    return cur;
}

pub fn get(ty: *const Type, specifier: Specifier) ?*const Type {
    std.debug.assert(specifier != .typeof_type and specifier != .typeof_expr);
    return switch (ty.specifier) {
        .typeof_type => ty.data.sub_type.get(specifier),
        .typeof_expr => ty.data.expr.ty.get(specifier),
        .attributed => ty.data.attributed.base.get(specifier),
        else => if (ty.specifier == specifier) ty else null,
    };
}

pub fn requestedAlignment(ty: Type, comp: *const Compilation) ?u29 {
    return switch (ty.specifier) {
        .typeof_type, .decayed_typeof_type => ty.data.sub_type.requestedAlignment(comp),
        .typeof_expr, .decayed_typeof_expr => ty.data.expr.ty.requestedAlignment(comp),
        .attributed => annotationAlignment(comp, ty.data.attributed.attributes),
        else => null,
    };
}

pub fn enumIsPacked(ty: Type, comp: *const Compilation) bool {
    std.debug.assert(ty.is(.@"enum"));
    return comp.langopts.short_enums or target.packAllEnums(comp.target) or ty.hasAttribute(.@"packed");
}

pub fn annotationAlignment(comp: *const Compilation, attrs: ?[]const Attribute) ?u29 {
    const a = attrs orelse return null;

    var max_requested: ?u29 = null;
    for (a) |attribute| {
        if (attribute.tag != .aligned) continue;
        const requested = if (attribute.args.aligned.alignment) |alignment| alignment.requested else target.defaultAlignment(comp.target);
        if (max_requested == null or max_requested.? < requested) {
            max_requested = requested;
        }
    }
    return max_requested;
}

pub fn eql(a_param: Type, b_param: Type, comp: *const Compilation, check_qualifiers: bool) bool {
    const a = a_param.canonicalize(.standard);
    const b = b_param.canonicalize(.standard);

    if (a.alignof(comp) != b.alignof(comp)) return false;
    if (a.isPtr()) {
        if (!b.isPtr()) return false;
    } else if (a.isFunc()) {
        if (!b.isFunc()) return false;
    } else if (a.isArray()) {
        if (!b.isArray()) return false;
    } else if (a.specifier != b.specifier) return false;

    if (a.qual.atomic != b.qual.atomic) return false;
    if (check_qualifiers) {
        if (a.qual.@"const" != b.qual.@"const") return false;
        if (a.qual.@"volatile" != b.qual.@"volatile") return false;
    }

    switch (a.specifier) {
        .pointer,
        .decayed_array,
        .decayed_static_array,
        .decayed_incomplete_array,
        .decayed_variable_len_array,
        .decayed_unspecified_variable_len_array,
        => if (!a_param.elemType().eql(b_param.elemType(), comp, check_qualifiers)) return false,

        .func,
        .var_args_func,
        .old_style_func,
        => {
            // TODO validate this
            if (a.data.func.params.len != b.data.func.params.len) return false;
            // return type cannot have qualifiers
            if (!a.returnType().eql(b.returnType(), comp, false)) return false;
            for (a.data.func.params) |param, i| {
                var a_unqual = param.ty;
                a_unqual.qual.@"const" = false;
                a_unqual.qual.@"volatile" = false;
                var b_unqual = b.data.func.params[i].ty;
                b_unqual.qual.@"const" = false;
                b_unqual.qual.@"volatile" = false;
                if (!a_unqual.eql(b_unqual, comp, check_qualifiers)) return false;
            }
        },

        .array,
        .static_array,
        .incomplete_array,
        .vector,
        => {
            if (!std.meta.eql(a.arrayLen(), b.arrayLen())) return false;
            if (!a.elemType().eql(b.elemType(), comp, check_qualifiers)) return false;
        },
        .variable_len_array => if (!a.elemType().eql(b.elemType(), comp, check_qualifiers)) return false,

        .@"struct", .@"union" => if (a.data.record != b.data.record) return false,
        .@"enum" => if (a.data.@"enum" != b.data.@"enum") return false,

        else => {},
    }
    return true;
}

/// Decays an array to a pointer
pub fn decayArray(ty: *Type) void {
    // the decayed array type is the current specifier +1
    ty.specifier = @intToEnum(Type.Specifier, @enumToInt(ty.specifier) + 1);
}

pub fn originalTypeOfDecayedArray(ty: Type) Type {
    std.debug.assert(ty.isDecayed());
    var copy = ty;
    copy.specifier = @intToEnum(Type.Specifier, @enumToInt(ty.specifier) - 1);
    return copy;
}

pub fn makeReal(ty: Type) Type {
    // TODO discards attributed/typeof
    var base = ty.canonicalize(.standard);
    switch (base.specifier) {
        .complex_fp16, .complex_float, .complex_double, .complex_long_double, .complex_float80, .complex_float128 => {
            base.specifier = @intToEnum(Type.Specifier, @enumToInt(base.specifier) - 6);
            return base;
        },
        .complex_char, .complex_schar, .complex_uchar, .complex_short, .complex_ushort, .complex_int, .complex_uint, .complex_long, .complex_ulong, .complex_long_long, .complex_ulong_long, .complex_int128, .complex_uint128 => {
            base.specifier = @intToEnum(Type.Specifier, @enumToInt(base.specifier) - 13);
            return base;
        },
        .complex_bit_int => {
            base.specifier = .bit_int;
            return base;
        },
        else => return ty,
    }
}

pub fn makeComplex(ty: Type) Type {
    // TODO discards attributed/typeof
    var base = ty.canonicalize(.standard);
    switch (base.specifier) {
        .fp16, .float, .double, .long_double, .float80, .float128 => {
            base.specifier = @intToEnum(Type.Specifier, @enumToInt(base.specifier) + 6);
            return base;
        },
        .char, .schar, .uchar, .short, .ushort, .int, .uint, .long, .ulong, .long_long, .ulong_long, .int128, .uint128 => {
            base.specifier = @intToEnum(Type.Specifier, @enumToInt(base.specifier) + 13);
            return base;
        },
        .bit_int => {
            base.specifier = .complex_bit_int;
            return base;
        },
        else => return ty,
    }
}

/// Combines types recursively in the order they were parsed, uses `.void` specifier as a sentinel value.
pub fn combine(inner: *Type, outer: Type) Parser.Error!void {
    switch (inner.specifier) {
        .pointer => return inner.data.sub_type.combine(outer),
        .unspecified_variable_len_array => {
            try inner.data.sub_type.combine(outer);
        },
        .variable_len_array => {
            try inner.data.expr.ty.combine(outer);
        },
        .array, .static_array, .incomplete_array => {
            try inner.data.array.elem.combine(outer);
        },
        .func, .var_args_func, .old_style_func => {
            try inner.data.func.return_type.combine(outer);
        },
        .decayed_array,
        .decayed_static_array,
        .decayed_incomplete_array,
        .decayed_variable_len_array,
        .decayed_unspecified_variable_len_array,
        .decayed_typeof_type,
        .decayed_typeof_expr,
        => unreachable, // type should not be able to decay before being combined
        .void => inner.* = outer,
        else => unreachable,
    }
}

pub fn validateCombinedType(ty: Type, p: *Parser, source_tok: TokenIndex) Parser.Error!void {
    switch (ty.specifier) {
        .pointer => return ty.data.sub_type.validateCombinedType(p, source_tok),
        .unspecified_variable_len_array,
        .variable_len_array,
        .array,
        .static_array,
        .incomplete_array,
        => {
            const elem_ty = ty.elemType();
            if (elem_ty.hasIncompleteSize()) {
                try p.errStr(.array_incomplete_elem, source_tok, try p.typeStr(elem_ty));
                return error.ParsingFailed;
            }
            if (elem_ty.isFunc()) {
                try p.errTok(.array_func_elem, source_tok);
                return error.ParsingFailed;
            }
            if (elem_ty.specifier == .static_array and elem_ty.isArray()) {
                try p.errTok(.static_non_outermost_array, source_tok);
            }
            if (elem_ty.anyQual() and elem_ty.isArray()) {
                try p.errTok(.qualifier_non_outermost_array, source_tok);
            }
        },
        .func, .var_args_func, .old_style_func => {
            const ret_ty = &ty.data.func.return_type;
            if (ret_ty.isArray()) try p.errTok(.func_cannot_return_array, source_tok);
            if (ret_ty.isFunc()) try p.errTok(.func_cannot_return_func, source_tok);
            if (ret_ty.qual.@"const") {
                try p.errStr(.qual_on_ret_type, source_tok, "const");
                ret_ty.qual.@"const" = false;
            }
            if (ret_ty.qual.@"volatile") {
                try p.errStr(.qual_on_ret_type, source_tok, "volatile");
                ret_ty.qual.@"volatile" = false;
            }
            if (ret_ty.qual.atomic) {
                try p.errStr(.qual_on_ret_type, source_tok, "atomic");
                ret_ty.qual.atomic = false;
            }
        },
        .typeof_type, .decayed_typeof_type => return ty.data.sub_type.validateCombinedType(p, source_tok),
        .typeof_expr, .decayed_typeof_expr => return ty.data.expr.ty.validateCombinedType(p, source_tok),
        .attributed => return ty.data.attributed.base.validateCombinedType(p, source_tok),
        else => {},
    }
}

/// An unfinished Type
pub const Builder = struct {
    complex_tok: ?TokenIndex = null,
    bit_int_tok: ?TokenIndex = null,
    typedef: ?struct {
        tok: TokenIndex,
        ty: Type,
    } = null,
    specifier: Builder.Specifier = .none,
    qual: Qualifiers.Builder = .{},
    typeof: ?Type = null,
    /// When true an error is returned instead of adding a diagnostic message.
    /// Used for trying to combine typedef types.
    error_on_invalid: bool = false,

    pub const Specifier = union(enum) {
        none,
        void,
        nullptr_t,
        bool,
        char,
        schar,
        uchar,
        complex_char,
        complex_schar,
        complex_uchar,

        unsigned,
        signed,
        short,
        sshort,
        ushort,
        short_int,
        sshort_int,
        ushort_int,
        int,
        sint,
        uint,
        long,
        slong,
        ulong,
        long_int,
        slong_int,
        ulong_int,
        long_long,
        slong_long,
        ulong_long,
        long_long_int,
        slong_long_int,
        ulong_long_int,
        int128,
        sint128,
        uint128,
        complex_unsigned,
        complex_signed,
        complex_short,
        complex_sshort,
        complex_ushort,
        complex_short_int,
        complex_sshort_int,
        complex_ushort_int,
        complex_int,
        complex_sint,
        complex_uint,
        complex_long,
        complex_slong,
        complex_ulong,
        complex_long_int,
        complex_slong_int,
        complex_ulong_int,
        complex_long_long,
        complex_slong_long,
        complex_ulong_long,
        complex_long_long_int,
        complex_slong_long_int,
        complex_ulong_long_int,
        complex_int128,
        complex_sint128,
        complex_uint128,
        bit_int: i16,
        sbit_int: i16,
        ubit_int: i16,
        complex_bit_int: i16,
        complex_sbit_int: i16,
        complex_ubit_int: i16,

        fp16,
        float,
        double,
        long_double,
        float80,
        float128,
        complex,
        complex_fp16,
        complex_float,
        complex_double,
        complex_long_double,
        complex_float80,
        complex_float128,

        pointer: *Type,
        unspecified_variable_len_array: *Type,
        decayed_unspecified_variable_len_array: *Type,
        func: *Func,
        var_args_func: *Func,
        old_style_func: *Func,
        array: *Array,
        decayed_array: *Array,
        static_array: *Array,
        decayed_static_array: *Array,
        incomplete_array: *Array,
        decayed_incomplete_array: *Array,
        vector: *Array,
        variable_len_array: *Expr,
        decayed_variable_len_array: *Expr,
        @"struct": *Record,
        @"union": *Record,
        @"enum": *Enum,
        typeof_type: *Type,
        decayed_typeof_type: *Type,
        typeof_expr: *Expr,
        decayed_typeof_expr: *Expr,

        attributed: *Attributed,

        pub fn str(spec: Builder.Specifier, langopts: LangOpts) ?[]const u8 {
            return switch (spec) {
                .none => unreachable,
                .void => "void",
                .nullptr_t => "nullptr_t",
                .bool => if (langopts.standard.atLeast(.c2x)) "bool" else "_Bool",
                .char => "char",
                .schar => "signed char",
                .uchar => "unsigned char",
                .unsigned => "unsigned",
                .signed => "signed",
                .short => "short",
                .ushort => "unsigned short",
                .sshort => "signed short",
                .short_int => "short int",
                .sshort_int => "signed short int",
                .ushort_int => "unsigned short int",
                .int => "int",
                .sint => "signed int",
                .uint => "unsigned int",
                .long => "long",
                .slong => "signed long",
                .ulong => "unsigned long",
                .long_int => "long int",
                .slong_int => "signed long int",
                .ulong_int => "unsigned long int",
                .long_long => "long long",
                .slong_long => "signed long long",
                .ulong_long => "unsigned long long",
                .long_long_int => "long long int",
                .slong_long_int => "signed long long int",
                .ulong_long_int => "unsigned long long int",
                .int128 => "__int128",
                .sint128 => "signed __int128",
                .uint128 => "unsigned __int128",
                .bit_int => "_BitInt",
                .sbit_int => "signed _BitInt",
                .ubit_int => "unsigned _BitInt",
                .complex_char => "_Complex char",
                .complex_schar => "_Complex signed char",
                .complex_uchar => "_Complex unsigned char",
                .complex_unsigned => "_Complex unsigned",
                .complex_signed => "_Complex signed",
                .complex_short => "_Complex short",
                .complex_ushort => "_Complex unsigned short",
                .complex_sshort => "_Complex signed short",
                .complex_short_int => "_Complex short int",
                .complex_sshort_int => "_Complex signed short int",
                .complex_ushort_int => "_Complex unsigned short int",
                .complex_int => "_Complex int",
                .complex_sint => "_Complex signed int",
                .complex_uint => "_Complex unsigned int",
                .complex_long => "_Complex long",
                .complex_slong => "_Complex signed long",
                .complex_ulong => "_Complex unsigned long",
                .complex_long_int => "_Complex long int",
                .complex_slong_int => "_Complex signed long int",
                .complex_ulong_int => "_Complex unsigned long int",
                .complex_long_long => "_Complex long long",
                .complex_slong_long => "_Complex signed long long",
                .complex_ulong_long => "_Complex unsigned long long",
                .complex_long_long_int => "_Complex long long int",
                .complex_slong_long_int => "_Complex signed long long int",
                .complex_ulong_long_int => "_Complex unsigned long long int",
                .complex_int128 => "_Complex __int128",
                .complex_sint128 => "_Complex signed __int128",
                .complex_uint128 => "_Complex unsigned __int128",
                .complex_bit_int => "_Complex _BitInt",
                .complex_sbit_int => "_Complex signed _BitInt",
                .complex_ubit_int => "_Complex unsigned _BitInt",

                .fp16 => "__fp16",
                .float => "float",
                .double => "double",
                .long_double => "long double",
                .float80 => "__float80",
                .float128 => "__float128",
                .complex => "_Complex",
                .complex_fp16 => "_Complex __fp16",
                .complex_float => "_Complex float",
                .complex_double => "_Complex double",
                .complex_long_double => "_Complex long double",
                .complex_float80 => "_Complex __float80",
                .complex_float128 => "_Complex __float128",

                .attributed => |attributed| Builder.fromType(attributed.base).str(langopts),

                else => null,
            };
        }
    };

    pub fn finish(b: Builder, p: *Parser) Parser.Error!Type {
        var ty: Type = .{ .specifier = undefined };
        if (b.typedef) |typedef| {
            ty = typedef.ty;
            if (ty.isArray()) {
                var elem = ty.elemType();
                try b.qual.finish(p, &elem);
                // TODO this really should be easier
                switch (ty.specifier) {
                    .array, .static_array, .incomplete_array => {
                        var old = ty.data.array;
                        ty.data.array = try p.arena.create(Array);
                        ty.data.array.* = .{
                            .len = old.len,
                            .elem = elem,
                        };
                    },
                    .variable_len_array, .unspecified_variable_len_array => {
                        var old = ty.data.expr;
                        ty.data.expr = try p.arena.create(Expr);
                        ty.data.expr.* = .{
                            .node = old.node,
                            .ty = elem,
                        };
                    },
                    .typeof_type => {}, // TODO handle
                    .typeof_expr => {}, // TODO handle
                    .attributed => {}, // TODO handle
                    else => unreachable,
                }

                return ty;
            }
            try b.qual.finish(p, &ty);
            return ty;
        }
        switch (b.specifier) {
            .none => {
                if (b.typeof) |typeof| {
                    ty = typeof;
                } else {
                    ty.specifier = .int;
                    try p.err(.missing_type_specifier);
                }
            },
            .void => ty.specifier = .void,
            .nullptr_t => unreachable, // nullptr_t can only be accessed via typeof(nullptr)
            .bool => ty.specifier = .bool,
            .char => ty.specifier = .char,
            .schar => ty.specifier = .schar,
            .uchar => ty.specifier = .uchar,
            .complex_char => ty.specifier = .complex_char,
            .complex_schar => ty.specifier = .complex_schar,
            .complex_uchar => ty.specifier = .complex_uchar,

            .unsigned => ty.specifier = .uint,
            .signed => ty.specifier = .int,
            .short_int, .sshort_int, .short, .sshort => ty.specifier = .short,
            .ushort, .ushort_int => ty.specifier = .ushort,
            .int, .sint => ty.specifier = .int,
            .uint => ty.specifier = .uint,
            .long, .slong, .long_int, .slong_int => ty.specifier = .long,
            .ulong, .ulong_int => ty.specifier = .ulong,
            .long_long, .slong_long, .long_long_int, .slong_long_int => ty.specifier = .long_long,
            .ulong_long, .ulong_long_int => ty.specifier = .ulong_long,
            .int128, .sint128 => ty.specifier = .int128,
            .uint128 => ty.specifier = .uint128,
            .complex_unsigned => ty.specifier = .complex_uint,
            .complex_signed => ty.specifier = .complex_int,
            .complex_short_int, .complex_sshort_int, .complex_short, .complex_sshort => ty.specifier = .complex_short,
            .complex_ushort, .complex_ushort_int => ty.specifier = .complex_ushort,
            .complex_int, .complex_sint => ty.specifier = .complex_int,
            .complex_uint => ty.specifier = .complex_uint,
            .complex_long, .complex_slong, .complex_long_int, .complex_slong_int => ty.specifier = .complex_long,
            .complex_ulong, .complex_ulong_int => ty.specifier = .complex_ulong,
            .complex_long_long, .complex_slong_long, .complex_long_long_int, .complex_slong_long_int => ty.specifier = .complex_long_long,
            .complex_ulong_long, .complex_ulong_long_int => ty.specifier = .complex_ulong_long,
            .complex_int128, .complex_sint128 => ty.specifier = .complex_int128,
            .complex_uint128 => ty.specifier = .complex_uint128,
            .bit_int, .sbit_int, .ubit_int, .complex_bit_int, .complex_ubit_int, .complex_sbit_int => |bits| {
                const unsigned = b.specifier == .ubit_int or b.specifier == .complex_ubit_int;
                if (unsigned) {
                    if (bits < 1) {
                        try p.errStr(.unsigned_bit_int_too_small, b.bit_int_tok.?, b.specifier.str(p.comp.langopts).?);
                        return error.ParsingFailed;
                    }
                } else {
                    if (bits < 2) {
                        try p.errStr(.signed_bit_int_too_small, b.bit_int_tok.?, b.specifier.str(p.comp.langopts).?);
                        return error.ParsingFailed;
                    }
                }
                if (bits > 128) {
                    try p.errStr(.bit_int_too_big, b.bit_int_tok.?, b.specifier.str(p.comp.langopts).?);
                    return error.ParsingFailed;
                }
                ty.specifier = if (b.complex_tok != null) .complex_bit_int else .bit_int;
                ty.data = .{ .int = .{
                    .signedness = if (unsigned) .unsigned else .signed,
                    .bits = @intCast(u8, bits),
                } };
            },

            .fp16 => ty.specifier = .fp16,
            .float => ty.specifier = .float,
            .double => ty.specifier = .double,
            .long_double => ty.specifier = .long_double,
            .float80 => ty.specifier = .float80,
            .float128 => ty.specifier = .float128,
            .complex_fp16 => ty.specifier = .complex_fp16,
            .complex_float => ty.specifier = .complex_float,
            .complex_double => ty.specifier = .complex_double,
            .complex_long_double => ty.specifier = .complex_long_double,
            .complex_float80 => ty.specifier = .complex_float80,
            .complex_float128 => ty.specifier = .complex_float128,
            .complex => {
                try p.errTok(.plain_complex, p.tok_i - 1);
                ty.specifier = .complex_double;
            },

            .pointer => |data| {
                ty.specifier = .pointer;
                ty.data = .{ .sub_type = data };
            },
            .unspecified_variable_len_array => |data| {
                ty.specifier = .unspecified_variable_len_array;
                ty.data = .{ .sub_type = data };
            },
            .decayed_unspecified_variable_len_array => |data| {
                ty.specifier = .decayed_unspecified_variable_len_array;
                ty.data = .{ .sub_type = data };
            },
            .func => |data| {
                ty.specifier = .func;
                ty.data = .{ .func = data };
            },
            .var_args_func => |data| {
                ty.specifier = .var_args_func;
                ty.data = .{ .func = data };
            },
            .old_style_func => |data| {
                ty.specifier = .old_style_func;
                ty.data = .{ .func = data };
            },
            .array => |data| {
                ty.specifier = .array;
                ty.data = .{ .array = data };
            },
            .decayed_array => |data| {
                ty.specifier = .decayed_array;
                ty.data = .{ .array = data };
            },
            .static_array => |data| {
                ty.specifier = .static_array;
                ty.data = .{ .array = data };
            },
            .decayed_static_array => |data| {
                ty.specifier = .decayed_static_array;
                ty.data = .{ .array = data };
            },
            .incomplete_array => |data| {
                ty.specifier = .incomplete_array;
                ty.data = .{ .array = data };
            },
            .decayed_incomplete_array => |data| {
                ty.specifier = .decayed_incomplete_array;
                ty.data = .{ .array = data };
            },
            .vector => |data| {
                ty.specifier = .vector;
                ty.data = .{ .array = data };
            },
            .variable_len_array => |data| {
                ty.specifier = .variable_len_array;
                ty.data = .{ .expr = data };
            },
            .decayed_variable_len_array => |data| {
                ty.specifier = .decayed_variable_len_array;
                ty.data = .{ .expr = data };
            },
            .@"struct" => |data| {
                ty.specifier = .@"struct";
                ty.data = .{ .record = data };
            },
            .@"union" => |data| {
                ty.specifier = .@"union";
                ty.data = .{ .record = data };
            },
            .@"enum" => |data| {
                ty.specifier = .@"enum";
                ty.data = .{ .@"enum" = data };
            },
            .typeof_type => |data| {
                ty.specifier = .typeof_type;
                ty.data = .{ .sub_type = data };
            },
            .decayed_typeof_type => |data| {
                ty.specifier = .decayed_typeof_type;
                ty.data = .{ .sub_type = data };
            },
            .typeof_expr => |data| {
                ty.specifier = .typeof_expr;
                ty.data = .{ .expr = data };
            },
            .decayed_typeof_expr => |data| {
                ty.specifier = .decayed_typeof_expr;
                ty.data = .{ .expr = data };
            },
            .attributed => |data| {
                ty.specifier = .attributed;
                ty.data = .{ .attributed = data };
            },
        }
        if (!ty.isReal() and ty.isInt()) try p.errTok(.complex_int, b.complex_tok.?);
        try b.qual.finish(p, &ty);
        return ty;
    }

    fn cannotCombine(b: Builder, p: *Parser, source_tok: TokenIndex) !void {
        if (b.error_on_invalid) return error.CannotCombine;
        const ty_str = b.specifier.str(p.comp.langopts) orelse try p.typeStr(try b.finish(p));
        try p.errExtra(.cannot_combine_spec, source_tok, .{ .str = ty_str });
        if (b.typedef) |some| try p.errStr(.spec_from_typedef, some.tok, try p.typeStr(some.ty));
    }

    fn duplicateSpec(b: *Builder, p: *Parser, source_tok: TokenIndex, spec: []const u8) !void {
        if (b.error_on_invalid) return error.CannotCombine;
        if (p.comp.langopts.emulate != .clang) return b.cannotCombine(p, source_tok);
        try p.errStr(.duplicate_decl_spec, p.tok_i, spec);
    }

    pub fn combineFromTypeof(b: *Builder, p: *Parser, new: Type, source_tok: TokenIndex) Compilation.Error!void {
        if (b.typeof != null) return p.errStr(.cannot_combine_spec, source_tok, "typeof");
        if (b.specifier != .none) return p.errStr(.invalid_typeof, source_tok, @tagName(b.specifier));
        const inner = switch (new.specifier) {
            .typeof_type => new.data.sub_type.*,
            .typeof_expr => new.data.expr.ty,
            .nullptr_t => new, // typeof(nullptr) is special-cased to be an unwrapped typeof-expr
            else => unreachable,
        };

        b.typeof = switch (inner.specifier) {
            .attributed => inner.data.attributed.base,
            else => new,
        };
    }

    /// Try to combine type from typedef, returns true if successful.
    pub fn combineTypedef(b: *Builder, p: *Parser, typedef_ty: Type, name_tok: TokenIndex) bool {
        b.error_on_invalid = true;
        defer b.error_on_invalid = false;

        const new_spec = fromType(typedef_ty);
        b.combineExtra(p, new_spec, 0) catch |err| switch (err) {
            error.FatalError => unreachable, // we do not add any diagnostics
            error.OutOfMemory => unreachable, // we do not add any diagnostics
            error.ParsingFailed => unreachable, // we do not add any diagnostics
            error.CannotCombine => return false,
        };
        b.typedef = .{ .tok = name_tok, .ty = typedef_ty };
        return true;
    }

    pub fn combine(b: *Builder, p: *Parser, new: Builder.Specifier, source_tok: TokenIndex) !void {
        b.combineExtra(p, new, source_tok) catch |err| switch (err) {
            error.CannotCombine => unreachable,
            else => |e| return e,
        };
    }

    fn combineExtra(b: *Builder, p: *Parser, new: Builder.Specifier, source_tok: TokenIndex) !void {
        if (b.typeof != null) {
            if (b.error_on_invalid) return error.CannotCombine;
            try p.errStr(.invalid_typeof, source_tok, @tagName(new));
        }

        if (new == .complex) b.complex_tok = source_tok;
        if (new == .bit_int) b.bit_int_tok = source_tok;

        if (new == .int128 and !target.hasInt128(p.comp.target)) {
            try p.errStr(.type_not_supported_on_target, source_tok, "__int128");
        }

        switch (new) {
            else => switch (b.specifier) {
                .none => b.specifier = new,
                else => return b.cannotCombine(p, source_tok),
            },
            .signed => b.specifier = switch (b.specifier) {
                .none => .signed,
                .char => .schar,
                .short => .sshort,
                .short_int => .sshort_int,
                .int => .sint,
                .long => .slong,
                .long_int => .slong_int,
                .long_long => .slong_long,
                .long_long_int => .slong_long_int,
                .int128 => .sint128,
                .bit_int => |bits| .{ .sbit_int = bits },
                .complex => .complex_signed,
                .complex_char => .complex_schar,
                .complex_short => .complex_sshort,
                .complex_short_int => .complex_sshort_int,
                .complex_int => .complex_sint,
                .complex_long => .complex_slong,
                .complex_long_int => .complex_slong_int,
                .complex_long_long => .complex_slong_long,
                .complex_long_long_int => .complex_slong_long_int,
                .complex_int128 => .complex_sint128,
                .complex_bit_int => |bits| .{ .complex_sbit_int = bits },
                .signed,
                .sshort,
                .sshort_int,
                .sint,
                .slong,
                .slong_int,
                .slong_long,
                .slong_long_int,
                .sint128,
                .sbit_int,
                .complex_schar,
                .complex_signed,
                .complex_sshort,
                .complex_sshort_int,
                .complex_sint,
                .complex_slong,
                .complex_slong_int,
                .complex_slong_long,
                .complex_slong_long_int,
                .complex_sint128,
                .complex_sbit_int,
                => return b.duplicateSpec(p, source_tok, "signed"),
                else => return b.cannotCombine(p, source_tok),
            },
            .unsigned => b.specifier = switch (b.specifier) {
                .none => .unsigned,
                .char => .uchar,
                .short => .ushort,
                .short_int => .ushort_int,
                .int => .uint,
                .long => .ulong,
                .long_int => .ulong_int,
                .long_long => .ulong_long,
                .long_long_int => .ulong_long_int,
                .int128 => .uint128,
                .bit_int => |bits| .{ .ubit_int = bits },
                .complex => .complex_unsigned,
                .complex_char => .complex_uchar,
                .complex_short => .complex_ushort,
                .complex_short_int => .complex_ushort_int,
                .complex_int => .complex_uint,
                .complex_long => .complex_ulong,
                .complex_long_int => .complex_ulong_int,
                .complex_long_long => .complex_ulong_long,
                .complex_long_long_int => .complex_ulong_long_int,
                .complex_int128 => .complex_uint128,
                .complex_bit_int => |bits| .{ .complex_ubit_int = bits },
                .unsigned,
                .ushort,
                .ushort_int,
                .uint,
                .ulong,
                .ulong_int,
                .ulong_long,
                .ulong_long_int,
                .uint128,
                .ubit_int,
                .complex_uchar,
                .complex_unsigned,
                .complex_ushort,
                .complex_ushort_int,
                .complex_uint,
                .complex_ulong,
                .complex_ulong_int,
                .complex_ulong_long,
                .complex_ulong_long_int,
                .complex_uint128,
                .complex_ubit_int,
                => return b.duplicateSpec(p, source_tok, "unsigned"),
                else => return b.cannotCombine(p, source_tok),
            },
            .char => b.specifier = switch (b.specifier) {
                .none => .char,
                .unsigned => .uchar,
                .signed => .schar,
                .complex => .complex_char,
                .complex_signed => .complex_schar,
                .complex_unsigned => .complex_uchar,
                else => return b.cannotCombine(p, source_tok),
            },
            .short => b.specifier = switch (b.specifier) {
                .none => .short,
                .unsigned => .ushort,
                .signed => .sshort,
                .int => .short_int,
                .sint => .sshort_int,
                .uint => .ushort_int,
                .complex => .complex_short,
                .complex_signed => .complex_sshort,
                .complex_unsigned => .complex_ushort,
                else => return b.cannotCombine(p, source_tok),
            },
            .int => b.specifier = switch (b.specifier) {
                .none => .int,
                .signed => .sint,
                .unsigned => .uint,
                .short => .short_int,
                .sshort => .sshort_int,
                .ushort => .ushort_int,
                .long => .long_int,
                .slong => .slong_int,
                .ulong => .ulong_int,
                .long_long => .long_long_int,
                .slong_long => .slong_long_int,
                .ulong_long => .ulong_long_int,
                .complex => .complex_int,
                .complex_signed => .complex_sint,
                .complex_unsigned => .complex_uint,
                .complex_short => .complex_short_int,
                .complex_sshort => .complex_sshort_int,
                .complex_ushort => .complex_ushort_int,
                .complex_long => .complex_long_int,
                .complex_slong => .complex_slong_int,
                .complex_ulong => .complex_ulong_int,
                .complex_long_long => .complex_long_long_int,
                .complex_slong_long => .complex_slong_long_int,
                .complex_ulong_long => .complex_ulong_long_int,
                else => return b.cannotCombine(p, source_tok),
            },
            .long => b.specifier = switch (b.specifier) {
                .none => .long,
                .long => .long_long,
                .unsigned => .ulong,
                .signed => .long,
                .int => .long_int,
                .sint => .slong_int,
                .ulong => .ulong_long,
                .complex => .complex_long,
                .complex_signed => .complex_slong,
                .complex_unsigned => .complex_ulong,
                .complex_long => .complex_long_long,
                .complex_slong => .complex_slong_long,
                .complex_ulong => .complex_ulong_long,
                else => return b.cannotCombine(p, source_tok),
            },
            .int128 => b.specifier = switch (b.specifier) {
                .none => .int128,
                .unsigned => .uint128,
                .signed => .sint128,
                .complex => .complex_int128,
                .complex_signed => .complex_sint128,
                .complex_unsigned => .complex_uint128,
                else => return b.cannotCombine(p, source_tok),
            },
            .bit_int => b.specifier = switch (b.specifier) {
                .none => .{ .bit_int = new.bit_int },
                .unsigned => .{ .ubit_int = new.bit_int },
                .signed => .{ .sbit_int = new.bit_int },
                .complex => .{ .complex_bit_int = new.bit_int },
                .complex_signed => .{ .complex_sbit_int = new.bit_int },
                .complex_unsigned => .{ .complex_ubit_int = new.bit_int },
                else => return b.cannotCombine(p, source_tok),
            },
            .fp16 => b.specifier = switch (b.specifier) {
                .none => .fp16,
                .complex => .complex_fp16,
                else => return b.cannotCombine(p, source_tok),
            },
            .float => b.specifier = switch (b.specifier) {
                .none => .float,
                .complex => .complex_float,
                else => return b.cannotCombine(p, source_tok),
            },
            .double => b.specifier = switch (b.specifier) {
                .none => .double,
                .long => .long_double,
                .complex_long => .complex_long_double,
                .complex => .complex_double,
                else => return b.cannotCombine(p, source_tok),
            },
            .float80 => b.specifier = switch (b.specifier) {
                .none => .float80,
                .complex => .complex_float80,
                else => return b.cannotCombine(p, source_tok),
            },
            .float128 => b.specifier = switch (b.specifier) {
                .none => .float128,
                .complex => .complex_float128,
                else => return b.cannotCombine(p, source_tok),
            },
            .complex => b.specifier = switch (b.specifier) {
                .none => .complex,
                .fp16 => .complex_fp16,
                .float => .complex_float,
                .double => .complex_double,
                .long_double => .complex_long_double,
                .float80 => .complex_float80,
                .float128 => .complex_float128,
                .char => .complex_char,
                .schar => .complex_schar,
                .uchar => .complex_uchar,
                .unsigned => .complex_unsigned,
                .signed => .complex_signed,
                .short => .complex_short,
                .sshort => .complex_sshort,
                .ushort => .complex_ushort,
                .short_int => .complex_short_int,
                .sshort_int => .complex_sshort_int,
                .ushort_int => .complex_ushort_int,
                .int => .complex_int,
                .sint => .complex_sint,
                .uint => .complex_uint,
                .long => .complex_long,
                .slong => .complex_slong,
                .ulong => .complex_ulong,
                .long_int => .complex_long_int,
                .slong_int => .complex_slong_int,
                .ulong_int => .complex_ulong_int,
                .long_long => .complex_long_long,
                .slong_long => .complex_slong_long,
                .ulong_long => .complex_ulong_long,
                .long_long_int => .complex_long_long_int,
                .slong_long_int => .complex_slong_long_int,
                .ulong_long_int => .complex_ulong_long_int,
                .int128 => .complex_int128,
                .sint128 => .complex_sint128,
                .uint128 => .complex_uint128,
                .bit_int => |bits| .{ .complex_bit_int = bits },
                .sbit_int => |bits| .{ .complex_sbit_int = bits },
                .ubit_int => |bits| .{ .complex_ubit_int = bits },
                .complex,
                .complex_fp16,
                .complex_float,
                .complex_double,
                .complex_long_double,
                .complex_float80,
                .complex_float128,
                .complex_char,
                .complex_schar,
                .complex_uchar,
                .complex_unsigned,
                .complex_signed,
                .complex_short,
                .complex_sshort,
                .complex_ushort,
                .complex_short_int,
                .complex_sshort_int,
                .complex_ushort_int,
                .complex_int,
                .complex_sint,
                .complex_uint,
                .complex_long,
                .complex_slong,
                .complex_ulong,
                .complex_long_int,
                .complex_slong_int,
                .complex_ulong_int,
                .complex_long_long,
                .complex_slong_long,
                .complex_ulong_long,
                .complex_long_long_int,
                .complex_slong_long_int,
                .complex_ulong_long_int,
                .complex_int128,
                .complex_sint128,
                .complex_uint128,
                .complex_bit_int,
                .complex_sbit_int,
                .complex_ubit_int,
                => return b.duplicateSpec(p, source_tok, "_Complex"),
                else => return b.cannotCombine(p, source_tok),
            },
        }
    }

    pub fn fromType(ty: Type) Builder.Specifier {
        return switch (ty.specifier) {
            .void => .void,
            .nullptr_t => .nullptr_t,
            .bool => .bool,
            .char => .char,
            .schar => .schar,
            .uchar => .uchar,
            .short => .short,
            .ushort => .ushort,
            .int => .int,
            .uint => .uint,
            .long => .long,
            .ulong => .ulong,
            .long_long => .long_long,
            .ulong_long => .ulong_long,
            .int128 => .int128,
            .uint128 => .uint128,
            .bit_int => if (ty.data.int.signedness == .unsigned) {
                return .{ .ubit_int = ty.data.int.bits };
            } else {
                return .{ .bit_int = ty.data.int.bits };
            },
            .complex_char => .complex_char,
            .complex_schar => .complex_schar,
            .complex_uchar => .complex_uchar,
            .complex_short => .complex_short,
            .complex_ushort => .complex_ushort,
            .complex_int => .complex_int,
            .complex_uint => .complex_uint,
            .complex_long => .complex_long,
            .complex_ulong => .complex_ulong,
            .complex_long_long => .complex_long_long,
            .complex_ulong_long => .complex_ulong_long,
            .complex_int128 => .complex_int128,
            .complex_uint128 => .complex_uint128,
            .complex_bit_int => if (ty.data.int.signedness == .unsigned) {
                return .{ .complex_ubit_int = ty.data.int.bits };
            } else {
                return .{ .complex_bit_int = ty.data.int.bits };
            },
            .fp16 => .fp16,
            .float => .float,
            .double => .double,
            .float80 => .float80,
            .float128 => .float128,
            .long_double => .long_double,
            .complex_fp16 => .complex_fp16,
            .complex_float => .complex_float,
            .complex_double => .complex_double,
            .complex_long_double => .complex_long_double,
            .complex_float80 => .complex_float80,
            .complex_float128 => .complex_float128,

            .pointer => .{ .pointer = ty.data.sub_type },
            .unspecified_variable_len_array => .{ .unspecified_variable_len_array = ty.data.sub_type },
            .decayed_unspecified_variable_len_array => .{ .decayed_unspecified_variable_len_array = ty.data.sub_type },
            .func => .{ .func = ty.data.func },
            .var_args_func => .{ .var_args_func = ty.data.func },
            .old_style_func => .{ .old_style_func = ty.data.func },
            .array => .{ .array = ty.data.array },
            .decayed_array => .{ .decayed_array = ty.data.array },
            .static_array => .{ .static_array = ty.data.array },
            .decayed_static_array => .{ .decayed_static_array = ty.data.array },
            .incomplete_array => .{ .incomplete_array = ty.data.array },
            .decayed_incomplete_array => .{ .decayed_incomplete_array = ty.data.array },
            .vector => .{ .vector = ty.data.array },
            .variable_len_array => .{ .variable_len_array = ty.data.expr },
            .decayed_variable_len_array => .{ .decayed_variable_len_array = ty.data.expr },
            .@"struct" => .{ .@"struct" = ty.data.record },
            .@"union" => .{ .@"union" = ty.data.record },
            .@"enum" => .{ .@"enum" = ty.data.@"enum" },

            .typeof_type => .{ .typeof_type = ty.data.sub_type },
            .decayed_typeof_type => .{ .decayed_typeof_type = ty.data.sub_type },
            .typeof_expr => .{ .typeof_expr = ty.data.expr },
            .decayed_typeof_expr => .{ .decayed_typeof_expr = ty.data.expr },

            .attributed => .{ .attributed = ty.data.attributed },
            else => unreachable,
        };
    }
};

pub fn getAttribute(ty: Type, comptime tag: Attribute.Tag) ?Attribute.ArgumentsForTag(tag) {
    switch (ty.specifier) {
        .typeof_type => return ty.data.sub_type.getAttribute(tag),
        .typeof_expr => return ty.data.expr.ty.getAttribute(tag),
        .attributed => {
            for (ty.data.attributed.attributes) |attribute| {
                if (attribute.tag == tag) return @field(attribute.args, @tagName(tag));
            }
            return null;
        },
        else => return null,
    }
}

pub fn hasAttribute(ty: Type, tag: Attribute.Tag) bool {
    for (ty.getAttributes()) |attr| {
        if (attr.tag == tag) return true;
    }
    return false;
}

/// Print type in C style
pub fn print(ty: Type, mapper: StringInterner.TypeMapper, langopts: LangOpts, w: anytype) @TypeOf(w).Error!void {
    _ = try ty.printPrologue(mapper, langopts, w);
    try ty.printEpilogue(mapper, langopts, w);
}

pub fn printNamed(ty: Type, name: []const u8, mapper: StringInterner.TypeMapper, langopts: LangOpts, w: anytype) @TypeOf(w).Error!void {
    const simple = try ty.printPrologue(mapper, langopts, w);
    if (simple) try w.writeByte(' ');
    try w.writeAll(name);
    try ty.printEpilogue(mapper, langopts, w);
}

const StringGetter = fn (TokenIndex) []const u8;

/// return true if `ty` is simple
fn printPrologue(ty: Type, mapper: StringInterner.TypeMapper, langopts: LangOpts, w: anytype) @TypeOf(w).Error!bool {
    if (ty.qual.atomic) {
        var non_atomic_ty = ty;
        non_atomic_ty.qual.atomic = false;
        try w.writeAll("_Atomic(");
        try non_atomic_ty.print(mapper, langopts, w);
        try w.writeAll(")");
        return true;
    }
    switch (ty.specifier) {
        .pointer,
        .decayed_array,
        .decayed_static_array,
        .decayed_incomplete_array,
        .decayed_variable_len_array,
        .decayed_unspecified_variable_len_array,
        .decayed_typeof_type,
        .decayed_typeof_expr,
        => {
            const elem_ty = ty.elemType();
            const simple = try elem_ty.printPrologue(mapper, langopts, w);
            if (simple) try w.writeByte(' ');
            if (elem_ty.isFunc() or elem_ty.isArray()) try w.writeByte('(');
            try w.writeByte('*');
            try ty.qual.dump(w);
            return false;
        },
        .func, .var_args_func, .old_style_func => {
            const ret_ty = ty.data.func.return_type;
            const simple = try ret_ty.printPrologue(mapper, langopts, w);
            if (simple) try w.writeByte(' ');
            return false;
        },
        .array, .static_array, .incomplete_array, .unspecified_variable_len_array, .variable_len_array => {
            const elem_ty = ty.elemType();
            const simple = try elem_ty.printPrologue(mapper, langopts, w);
            if (simple) try w.writeByte(' ');
            return false;
        },
        .typeof_type, .typeof_expr => {
            const actual = ty.canonicalize(.standard);
            return actual.printPrologue(mapper, langopts, w);
        },
        .attributed => {
            const actual = ty.canonicalize(.standard);
            return actual.printPrologue(mapper, langopts, w);
        },
        else => {},
    }
    try ty.qual.dump(w);

    switch (ty.specifier) {
        .@"enum" => if (ty.data.@"enum".fixed) {
            try w.print("enum {s}: ", .{mapper.lookup(ty.data.@"enum".name)});
            try ty.data.@"enum".tag_ty.dump(mapper, langopts, w);
        } else {
            try w.print("enum {s}", .{mapper.lookup(ty.data.@"enum".name)});
        },
        .@"struct" => try w.print("struct {s}", .{mapper.lookup(ty.data.record.name)}),
        .@"union" => try w.print("union {s}", .{mapper.lookup(ty.data.record.name)}),
        .vector => {
            const len = ty.data.array.len;
            const elem_ty = ty.data.array.elem;
            try w.print("__attribute__((__vector_size__({d} * sizeof(", .{len});
            _ = try elem_ty.printPrologue(mapper, langopts, w);
            try w.writeAll(")))) ");
            _ = try elem_ty.printPrologue(mapper, langopts, w);
            try w.print(" (vector of {d} '", .{len});
            _ = try elem_ty.printPrologue(mapper, langopts, w);
            try w.writeAll("' values)");
        },
        else => try w.writeAll(Builder.fromType(ty).str(langopts).?),
    }
    return true;
}

fn printEpilogue(ty: Type, mapper: StringInterner.TypeMapper, langopts: LangOpts, w: anytype) @TypeOf(w).Error!void {
    if (ty.qual.atomic) return;
    switch (ty.specifier) {
        .pointer,
        .decayed_array,
        .decayed_static_array,
        .decayed_incomplete_array,
        .decayed_variable_len_array,
        .decayed_unspecified_variable_len_array,
        .decayed_typeof_type,
        .decayed_typeof_expr,
        => {
            const elem_ty = ty.elemType();
            if (elem_ty.isFunc() or elem_ty.isArray()) try w.writeByte(')');
            try elem_ty.printEpilogue(mapper, langopts, w);
        },
        .func, .var_args_func, .old_style_func => {
            try w.writeByte('(');
            for (ty.data.func.params) |param, i| {
                if (i != 0) try w.writeAll(", ");
                _ = try param.ty.printPrologue(mapper, langopts, w);
                try param.ty.printEpilogue(mapper, langopts, w);
            }
            if (ty.specifier != .func) {
                if (ty.data.func.params.len != 0) try w.writeAll(", ");
                try w.writeAll("...");
            } else if (ty.data.func.params.len == 0) {
                try w.writeAll("void");
            }
            try w.writeByte(')');
            try ty.data.func.return_type.printEpilogue(mapper, langopts, w);
        },
        .array, .static_array => {
            try w.writeByte('[');
            if (ty.specifier == .static_array) try w.writeAll("static ");
            try ty.qual.dump(w);
            try w.print("{d}]", .{ty.data.array.len});
            try ty.data.array.elem.printEpilogue(mapper, langopts, w);
        },
        .incomplete_array => {
            try w.writeByte('[');
            try ty.qual.dump(w);
            try w.writeByte(']');
            try ty.data.array.elem.printEpilogue(mapper, langopts, w);
        },
        .unspecified_variable_len_array => {
            try w.writeByte('[');
            try ty.qual.dump(w);
            try w.writeAll("*]");
            try ty.data.sub_type.printEpilogue(mapper, langopts, w);
        },
        .variable_len_array => {
            try w.writeByte('[');
            try ty.qual.dump(w);
            try w.writeAll("<expr>]");
            try ty.data.expr.ty.printEpilogue(mapper, langopts, w);
        },
        .typeof_type, .typeof_expr => {
            const actual = ty.canonicalize(.standard);
            try actual.printEpilogue(mapper, langopts, w);
        },
        .attributed => {
            const actual = ty.canonicalize(.standard);
            try actual.printEpilogue(mapper, langopts, w);
        },
        else => {},
    }
}

/// Useful for debugging, too noisy to be enabled by default.
const dump_detailed_containers = false;

// Print as Zig types since those are actually readable
pub fn dump(ty: Type, mapper: StringInterner.TypeMapper, langopts: LangOpts, w: anytype) @TypeOf(w).Error!void {
    try ty.qual.dump(w);
    switch (ty.specifier) {
        .invalid => try w.writeAll("invalid"),
        .pointer => {
            try w.writeAll("*");
            try ty.data.sub_type.dump(mapper, langopts, w);
        },
        .func, .var_args_func, .old_style_func => {
            try w.writeAll("fn (");
            for (ty.data.func.params) |param, i| {
                if (i != 0) try w.writeAll(", ");
                if (param.name != .empty) try w.print("{s}: ", .{mapper.lookup(param.name)});
                try param.ty.dump(mapper, langopts, w);
            }
            if (ty.specifier != .func) {
                if (ty.data.func.params.len != 0) try w.writeAll(", ");
                try w.writeAll("...");
            }
            try w.writeAll(") ");
            try ty.data.func.return_type.dump(mapper, langopts, w);
        },
        .array, .static_array, .decayed_array, .decayed_static_array => {
            if (ty.specifier == .decayed_array or ty.specifier == .decayed_static_array) try w.writeByte('d');
            try w.writeByte('[');
            if (ty.specifier == .static_array or ty.specifier == .decayed_static_array) try w.writeAll("static ");
            try w.print("{d}]", .{ty.data.array.len});
            try ty.data.array.elem.dump(mapper, langopts, w);
        },
        .vector => {
            try w.print("vector({d}, ", .{ty.data.array.len});
            try ty.data.array.elem.dump(mapper, langopts, w);
            try w.writeAll(")");
        },
        .incomplete_array, .decayed_incomplete_array => {
            if (ty.specifier == .decayed_incomplete_array) try w.writeByte('d');
            try w.writeAll("[]");
            try ty.data.array.elem.dump(mapper, langopts, w);
        },
        .@"enum" => {
            const enum_ty = ty.data.@"enum";
            if (enum_ty.isIncomplete() and !enum_ty.fixed) {
                try w.print("enum {s}", .{mapper.lookup(enum_ty.name)});
            } else {
                try w.print("enum {s}: ", .{mapper.lookup(enum_ty.name)});
                try enum_ty.tag_ty.dump(mapper, langopts, w);
            }
            if (dump_detailed_containers) try dumpEnum(enum_ty, mapper, w);
        },
        .@"struct" => {
            try w.print("struct {s}", .{mapper.lookup(ty.data.record.name)});
            if (dump_detailed_containers) try dumpRecord(ty.data.record, mapper, langopts, w);
        },
        .@"union" => {
            try w.print("union {s}", .{mapper.lookup(ty.data.record.name)});
            if (dump_detailed_containers) try dumpRecord(ty.data.record, mapper, langopts, w);
        },
        .unspecified_variable_len_array, .decayed_unspecified_variable_len_array => {
            if (ty.specifier == .decayed_unspecified_variable_len_array) try w.writeByte('d');
            try w.writeAll("[*]");
            try ty.data.sub_type.dump(mapper, langopts, w);
        },
        .variable_len_array, .decayed_variable_len_array => {
            if (ty.specifier == .decayed_variable_len_array) try w.writeByte('d');
            try w.writeAll("[<expr>]");
            try ty.data.expr.ty.dump(mapper, langopts, w);
        },
        .typeof_type, .decayed_typeof_type => {
            try w.writeAll("typeof(");
            try ty.data.sub_type.dump(mapper, langopts, w);
            try w.writeAll(")");
        },
        .typeof_expr, .decayed_typeof_expr => {
            try w.writeAll("typeof(<expr>: ");
            try ty.data.expr.ty.dump(mapper, langopts, w);
            try w.writeAll(")");
        },
        .attributed => {
            try w.writeAll("attributed(");
            try ty.data.attributed.base.dump(mapper, langopts, w);
            try w.writeAll(")");
        },
        .special_va_start => try w.writeAll("(va start param)"),
        else => try w.writeAll(Builder.fromType(ty).str(langopts).?),
    }
}

fn dumpEnum(@"enum": *Enum, mapper: StringInterner.TypeMapper, w: anytype) @TypeOf(w).Error!void {
    try w.writeAll(" {");
    for (@"enum".fields) |field| {
        try w.print(" {s} = {d},", .{ mapper.lookup(field.name), field.value });
    }
    try w.writeAll(" }");
}

fn dumpRecord(record: *Record, mapper: StringInterner.TypeMapper, langopts: LangOpts, w: anytype) @TypeOf(w).Error!void {
    try w.writeAll(" {");
    for (record.fields) |field| {
        try w.writeByte(' ');
        try field.ty.dump(mapper, langopts, w);
        try w.print(" {s}: {d};", .{ mapper.lookup(field.name), field.bit_width });
    }
    try w.writeAll(" }");
}
