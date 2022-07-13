const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const assert = std.debug.assert;
const testing = std.testing;
const builtin = std.builtin;
const unicode = std.unicode;
const Allocator = std.mem.Allocator;

/// checks if the provided type is a custom serializable type
pub fn isSerializable(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .Struct and info != .Union and info != .Enum) return false;
    inline for (.{ "write", "read", "size", "UserType" }) |name| {
        if (!@hasDecl(T, name)) return false;
    }
    return true;
}

pub fn GetUserType(comptime Partial: type) type {
    if (isSerializable(Partial)) {
        return Partial.UserType;
    } else {
        return switch (@typeInfo(Partial)) {
            .Struct => StructUserType(Partial),
            .Union => UnionUserType(Partial),
            .Optional => OptionalUserType(Partial),
            .Void, .Int, .Float, .Enum => Partial,
            else => @compileError("Unable to generate a user type for: " ++ @typeName(Partial)),
        };
    }
}
pub fn OptionalUserType(comptime Partial: type) type {
    const child = @typeInfo(Partial).Optional.child;
    return ?GetUserType(child);
}

/// generates the user type given a struct's partial spec
pub fn StructUserType(comptime Partial: type) type {
    const info = @typeInfo(Partial).Struct;
    var fields: [info.fields.len]builtin.TypeInfo.StructField = undefined;
    inline for (info.fields) |*field, i| {
        const field_type = GetUserType(field.field_type);
        var f = field.*;
        f.field_type = field_type;
        f.default_value = null;
        fields[i] = f;
    }
    return @Type(builtin.TypeInfo{ .Struct = .{
        .layout = info.layout,
        .fields = &fields,
        .decls = &[_]builtin.TypeInfo.Declaration{},
        .is_tuple = info.is_tuple,
    } });
}

pub fn UnionUserType(comptime Partial: type) type {
    const info = @typeInfo(Partial).Union;
    var fields: [info.fields.len]builtin.TypeInfo.UnionField = undefined;
    inline for (info.fields) |*field, i| {
        const field_type = GetUserType(field.field_type);
        var f = field.*;
        f.field_type = field_type;
        fields[i] = f;
    }
    return @Type(builtin.TypeInfo{ .Union = .{
        .layout = info.layout,
        .tag_type = info.tag_type,
        .fields = &fields,
        .decls = &[_]std.builtin.TypeInfo.Declaration{},
    } });
}

/// calls UsedSpec.Spec on each field type of Partial and puts it into a list
pub fn fieldSpecs(
    comptime UsedSpec: type,
    comptime Partial: type,
    comptime UserType: type,
) [meta.fields(Partial).len]type {
    const fields = meta.fields(Partial);
    const user_fields = meta.fields(UserType);
    var specs: [fields.len]type = undefined;
    inline for (fields) |field, i| {
        const SpecType = UsedSpec.Spec(
            field.field_type,
            user_fields[i].field_type,
        );
        specs[i] = SpecType;
    }
    return specs;
}
/// checks if the provided specs are all constant size, and if so, what constant size
pub fn ConstantStructSize(comptime Specs: anytype) ?comptime_int {
    comptime var total_size = 0;
    inline for (Specs) |spec| {
        if (@hasDecl(spec, "Size")) {
            total_size += spec.Size;
        } else {
            return null;
        }
    }
    return total_size;
}

/// checks if the provided specs use allocation
pub fn SpecsUseAllocation(comptime Specs: anytype) bool {
    inline for (Specs) |spec| {
        if (@hasDecl(spec, "readAlloc")) {
            return true;
        }
    }
    return false;
}

pub const bare = struct {
    pub fn Spec(comptime Partial: type, comptime UserType: type) type {
        if (isSerializable(Partial)) return Partial;
        return switch (@typeInfo(Partial)) {
            .Int => Num(Partial, .Big), // Partial == UserType
            .Float => Num(Partial, .Big),
            .Void => Void,
            .Bool => Bool,
            .Struct => Struct(@This(), Partial, UserType),
            .Enum => |info| Enum(@This(), info.tag_type, UserType),
            .Optional => Optional(@This(), Partial, UserType),
            else => @compileError(
                "Bare serde does not support this type at the moment: " ++
                    @typeName(Partial),
            ),
        };
    }
};

/// basic void serialization type.
/// basically just doesnt do anything
pub const Void = struct {
    pub const UserType = void;
    pub const Stepped = void;
    pub const Size = 0;
    pub const SerdeName = .Void;

    pub fn write(self: UserType, writer: anytype) !void {
        _ = self;
        _ = writer;
    }
    pub fn size(self: UserType) usize {
        _ = self;
        return Size;
    }
    pub fn read(reader: anytype) !UserType {
        _ = reader;
    }
};

/// number serialization type for any int or float with specified endianness
pub fn Num(comptime T: type, comptime endian: std.builtin.Endian) type {
    const info = @typeInfo(T);
    if (info != .Int and info != .Float) {
        @compileError("expected an int or a float");
    } else if (info == .Int and (info.Int.bits % 8) != 0) {
        @compileError("Integer width must be divisible by 8");
    }
    return struct {
        const IntType = if (info == .Float) meta.Int(.unsigned, info.Float.bits) else T;
        pub const UserType = T;
        pub const Size = @sizeOf(T);
        pub const SerdeName = switch (endian) {
            .Big => .NumBig,
            .Little => .NumLittle,
        };

        pub fn write(self: UserType, writer: anytype) !void {
            switch (endian) {
                .Big => try writer.writeIntBig(IntType, @bitCast(IntType, self)),
                .Little => try writer.writeIntLittle(IntType, @bitCast(IntType, self)),
            }
        }
        pub fn size(self: UserType) usize {
            _ = self;
            return Size;
        }
        pub fn writeConstant(self: UserType, target: *[Size]u8) void {
            switch (endian) {
                .Big => mem.writeIntBig(IntType, target, @bitCast(IntType, self)),
                .Little => mem.writeIntLittle(IntType, target, @bitCast(IntType, self)),
            }
        }

        pub fn read(reader: anytype) !UserType {
            const val = try reader.readInt(IntType, endian);
            return @bitCast(T, val);
        }
    };
}

/// bool serialization type. serialized as a single byte, true => 0x01 or => 0x00
/// currently implemented where read byte != 0x01 => false, else true
pub const Bool = struct {
    pub const UserType = bool;
    pub const Size = 1;
    pub const SerdeName = .Bool;

    pub fn write(self: UserType, writer: anytype) !void {
        try writer.writeByte(if (self) 0x01 else 0x00);
    }
    pub fn size(self: UserType) usize {
        _ = self;
        return Size;
    }
    pub fn writeConstant(self: UserType, target: *[Size]u8) void {
        target[0] = @boolToInt(self);
    }

    pub fn read(reader: anytype) !UserType {
        return (try reader.readByte()) == 0x01;
    }
};

/// serialization type for structs
/// will figure out which deserialization functions to use based on the discovered specs
pub fn Struct(comptime UsedSpec: type, comptime Partial: type, comptime userType: type) type {
    const info = @typeInfo(Partial).Struct;

    return struct {
        pub const UserType = userType;
        pub const Specs = fieldSpecs(UsedSpec, Partial, UserType);
        pub const SerdeName = .Struct;

        const Self = @This();

        pub fn write(self: anytype, writer: anytype) !void {
            inline for (info.fields) |field, i| {
                try Specs[i].write(@field(self, field.name), writer);
            }
        }
        pub fn size(self: anytype) usize {
            if (@hasDecl(Self, "Size")) {
                return Self.Size;
            } else {
                var total_size: usize = 0;
                inline for (info.fields) |field, i| {
                    total_size += Specs[i].size(@field(self, field.name));
                }
                return total_size;
            }
        }
        usingnamespace if (ConstantStructSize(Specs)) |constant_size| struct {
            pub const Size = constant_size;
            pub fn writeConstant(self: UserType, target: *[Size]u8) void {
                comptime var ind = 0;
                inline for (info.fields) |field, i| {
                    if (Specs[i].Size > 0) {
                        Specs[i].writeConstant(
                            @field(self, field.name),
                            target[ind .. ind + Specs[i].Size],
                        );
                        ind += Specs[i].Size;
                    }
                }
            }
        } else struct {};

        usingnamespace if (SpecsUseAllocation(Specs)) struct {
            pub const read = @compileError("Requires allocation");

            pub fn readAlloc(alloc: Allocator, reader: anytype) !UserType {
                var data: UserType = undefined;
                inline for (info.fields) |field, i| {
                    errdefer {
                        comptime var j = i;
                        inline while (j > 0) {
                            j -= 1;
                            if (@hasDecl(Specs[j], "readAlloc")) {
                                Specs[j].deinit(@field(data, info.fields[j].name), alloc);
                            }
                        }
                    }
                    if (@hasDecl(Specs[i], "readAlloc")) {
                        @field(data, field.name) = try Specs[i].readAlloc(alloc, reader);
                    } else {
                        @field(data, field.name) = try Specs[i].read(reader);
                    }
                }
                return data;
            }
            pub fn skip(reader: anytype) !void {
                if (@hasDecl(UserType, "Size")) {
                    try reader.skipBytes(Self.Size, .{
                        .buf_size = comptime std.math.min(Self.Size, 128),
                    });
                } else {
                    inline for (Specs) |spec| {
                        if (@hasDecl(spec, "readAlloc")) {
                            try spec.skip(reader);
                        } else {
                            _ = try spec.read(reader);
                        }
                    }
                }
            }
            pub fn deinit(self: UserType, alloc: Allocator) void {
                inline for (info.fields) |field, i| {
                    if (@hasDecl(Specs[i], "readAlloc")) {
                        Specs[i].deinit(@field(self, field.name), alloc);
                    }
                }
            }
        } else struct {
            pub fn read(reader: anytype) !UserType {
                var data: UserType = undefined;
                inline for (info.fields) |field, i| {
                    @field(data, field.name) = try Specs[i].read(reader);
                }
                return data;
            }
        };
    };
}

/// if all union paths are the same constant size, then this returns the size
pub fn ConstantUnionSize(comptime Specs: anytype) ?comptime_int {
    comptime var first_size = if (@hasDecl(Specs[0], "Size")) Specs[0].Size else return null;
    inline for (Specs) |spec| if (!@hasDecl(spec, "Size") or spec.Size != first_size) return null;
    return first_size;
}

pub fn Union(comptime UsedSpec: type, comptime PartialUnion: type, comptime userType: type) type {
    const partial_info = @typeInfo(PartialUnion);
    assert(partial_info.Union.tag_type != null);
    const user_info = @typeInfo(userType);
    return struct {
        pub const Specs = fieldSpecs(UsedSpec, PartialUnion);
        pub const UserType = userType;
        pub const TagType = user_info.Union.tag_type.?;
        pub const SerdeName = .Union;

        usingnamespace if (ConstantUnionSize(Specs)) |constant_size| struct {
            pub const Size = constant_size;
        } else struct {};

        pub const UserFields = user_info.Union.fields;
        const field_enum = meta.FieldEnum(meta.Tag(UserType));

        const Self = @This();

        pub fn getPrefix(self: UserType) TagType {
            return @as(TagType, self);
        }

        pub fn write(self: UserType, writer: anytype) !void {
            inline for (UserFields) |field, i| {
                if (@field(TagType, field.name) == @as(TagType, self)) {
                    const res = Specs[i].write(@field(self, field.name), writer);
                    if (meta.isError(res)) res catch |err| return err;
                    return;
                }
            }
            unreachable;
        }
        pub fn size(self: UserType) usize {
            inline for (UserFields) |field, i| {
                if (@field(TagType, field.name) == @as(TagType, self)) {
                    return Specs[i].size(@field(self, field.name));
                }
            }
            unreachable;
        }
        usingnamespace if (SpecsUseAllocation(Specs)) struct {
            pub const read = @compileError("Requires allocation");

            pub fn readAlloc(alloc: Allocator, reader: anytype, variant: TagType) !UserType {
                inline for (UserFields) |field, i| {
                    if (@field(TagType, field.name) == variant) {
                        // untested if this workaround is necessary for write, but it
                        // is necessary for deserialize https://github.com/ziglang/zig/issues/10087
                        const res = if (@hasDecl(Specs[i], "readAlloc"))
                            Specs[i].readAlloc(alloc, reader)
                        else
                            Specs[i].read(reader);
                        if (meta.isError(res)) _ = res catch |err| return err;
                        const val = res catch unreachable;
                        return @unionInit(UserType, field.name, val);
                    }
                }
                unreachable;
            }
            pub fn deinit(self: UserType, alloc: Allocator) void {
                inline for (UserFields) |field, i| {
                    if (@field(TagType, field.name) == @as(TagType, self)) {
                        if (@hasDecl(Specs[i], "readAlloc")) {
                            Specs[i].deinit(@field(self, field.name), alloc);
                        }
                        return;
                    }
                }
                unreachable;
            }
            pub fn skip(reader: anytype, variant: TagType) !void {
                if (@hasDecl(Self, "Size")) {
                    try reader.skipBytes(Self.Size, .{
                        .max_len = comptime std.math.min(Self.Size, 128),
                    });
                } else {
                    inline for (UserFields) |field, i| {
                        if (@field(TagType, field.name) == variant) {
                            const res = noRead(Specs[i], reader);
                            if (meta.isError(res)) _ = res catch |err| return err;
                            return;
                        }
                    }
                    unreachable;
                }
            }
        } else struct {
            pub fn read(reader: anytype, variant: TagType) !UserType {
                inline for (UserFields) |field, i| {
                    if (@field(TagType, field.name) == variant) {
                        const res = Specs[i].read(reader);
                        if (meta.isError(res)) _ = res catch |err| return err;
                        const val = res catch unreachable;
                        return @unionInit(UserType, field.name, val);
                    }
                }
                unreachable;
            }
        };
    };
}

/// preforms the equivalent to a skip on a serialization type, but accounts
/// for when type has no skip function and does not allocate
pub fn noRead(comptime Spec: type, reader: anytype) !void {
    if (@hasDecl(Spec, "readAlloc")) {
        try Spec.skip(reader);
    } else {
        _ = try Spec.read(reader);
    }
}

/// reads an integer into an enum. UserType is the provided enum
pub fn Enum(
    comptime UsedSpec: type,
    comptime PartialTag: type,
    comptime UserType: type,
) type {
    const Tag = UsedSpec.Spec(PartialTag, PartialTag);
    return AsEnum(Tag, UserType);
    // return struct {
    //     pub const TagType = UsedSpec.Spec(PartialTag);
    //     comptime {
    //         assert(@typeInfo(TagType.UserType) == .Int);
    //         assert(!@hasDecl(TagType, "readAlloc"));
    //     }
    //     pub const UserType = userType;
    //     pub const SerdeName = .Enum;

    //     const Self = @This();

    //     pub fn getInt(self: UserType) TagType.UserType {
    //         return @intCast(TagType.UserType, @enumToInt(self));
    //     }
    //     pub fn write(self: UserType, writer: anytype) !void {
    //         try TagType.write(getInt(self), writer);
    //     }
    //     pub fn size(self: UserType) usize {
    //         if (@hasDecl(Self, "Size")) {
    //             return Self.Size;
    //         } else {
    //             return TagType.size(getInt(self));
    //         }
    //     }
    //     usingnamespace if (@hasDecl(TagType, "Size")) struct {
    //         pub const Size = TagType.Size;
    //         pub fn writeConstant(self: UserType, target: *[Size]u8) void {
    //             TagType.writeConstant(getInt(self), target);
    //         }
    //     } else struct {};

    //     pub fn read(reader: anytype) !UserType {
    //         return try meta.intToEnum(UserType, try TagType.read(reader));
    //     }
    // };
}

pub fn AsEnum(comptime Inner: type, comptime Tag: type) type {
    assert(isSerializable(Inner));
    assert(@typeInfo(Tag) == .Enum);
    return struct {
        pub const InnerType = Inner;
        pub const UserType = Tag;
        pub const SerdeName = .Enum;
        usingnamespace if (@hasDecl(Inner, "Size")) struct {
            pub const Size = Inner.Size;
        } else struct {};

        pub fn write(self: UserType, writer: anytype) !void {
            try InnerType.write(@intCast(InnerType.UserType, @enumToInt(self)), writer);
        }
        pub fn size(self: anytype) usize {
            return InnerType.size(@intCast(InnerType.UserType, @enumToInt(self)));
        }
        pub fn read(reader: anytype) !UserType {
            return try meta.intToEnum(UserType, try InnerType.read(reader));
        }
    };
}

pub fn Prefixed(comptime Prefix: type, comptime T: type) type {
    assert(isSerializable(Prefix));
    assert(isSerializable(T));
    return struct {
        pub const InnerType = T;
        pub const PrefixType = Prefix;
        pub const UserType = InnerType.UserType;
        pub const SerdeName = .Prefix;
        usingnamespace if (@hasDecl(InnerType, "Size") and @hasDecl(PrefixType, "Size")) struct {
            pub const Size = InnerType.Size + PrefixType.Size;
        } else struct {};

        pub fn write(self: anytype, writer: anytype) !void {
            const prefix_data = InnerType.getPrefix(self);
            try PrefixType.write(prefix_data, writer);
            try InnerType.write(self, writer);
        }
        usingnamespace if (@hasDecl(InnerType, "readAlloc")) struct {
            pub const read = @compileError("Requires allocation");

            pub fn readAlloc(alloc: Allocator, reader: anytype) !UserType {
                const prefix_data = try PrefixType.read(reader);
                return try InnerType.readAlloc(alloc, reader, prefix_data);
            }
            pub fn deinit(self: UserType, alloc: Allocator) void {
                InnerType.deinit(self, alloc);
            }
        } else struct {
            pub fn read(reader: anytype) !UserType {
                const prefix_data = try PrefixType.read(reader);
                return try InnerType.read(reader, prefix_data);
            }
        };
        pub fn size(self: anytype) usize {
            const prefix_data = InnerType.getPrefix(self);
            return PrefixType.size(prefix_data) + InnerType.size(self);
        }
        pub fn skip(reader: anytype) !void {
            const prefix_data = try PrefixType.read(reader);
            try InnerType.skip(reader, prefix_data);
        }
    };
}
pub fn TaggedUnion(
    comptime UsedSpec: type,
    comptime PartialTag: type,
    comptime PartialUnion: type,
    comptime unionUserType: type,
) type {
    const Tag = UsedSpec.Spec(PartialTag, PartialTag);
    const UnionTag = @typeInfo(UnionUserType).tag_type.?;
    return Prefixed(AsEnum(Tag, UnionTag), Union(UsedSpec, PartialUnion, unionUserType));
}

pub fn IntRestricted(comptime Inner: type, comptime Int: type, comptime options: struct {
    max: ?comptime_int = null,
}) type {
    assert(isSerializable(Inner));
    assert(@typeInfo(Int) == .Int);
    return struct {
        pub const InnerType = Inner;
        pub const UserType = Int;
        pub const SerdeName = .Int;
        usingnamespace if (@hasDecl(Inner, "Size")) struct {
            pub const Size = Inner.Size;
        } else struct {};

        pub fn write(self: UserType, writer: anytype) !void {
            const num = @intCast(Inner.UserType, self); // TODO: should i use math.cast here?
            if (options.max) |max| if (num > max) return error.IntegerOutOfBounds;
            try Inner.write(num, writer);
        }
        pub fn size(self: anytype) usize {
            return Inner.size(@intCast(Inner.UserType, self));
        }
        pub fn read(reader: anytype) !UserType {
            const num = std.math.cast(UserType, try Inner.read(reader)) orelse {
                return error.CastFailure;
            };
            if (options.max) |max| if (num > max) return error.IntegerOutOfBounds;
            return num;
        }
    };
}

pub fn writeArray(comptime T: type, arr: []const T.UserType, writer: anytype) !void {
    // TODO: this check here shouldnt necessarily work all the time...
    if (T.UserType == u8 or T.UserType == i8 or T.UserType == bool) {
        const data = @bitCast([]const u8, arr);
        try writer.writeAll(data);
    } else {
        for (arr) |elem| {
            try T.write(elem, writer);
        }
    }
}
pub fn readArray(comptime T: type, data: []T.UserType, reader: anytype) !void {
    if (T.UserType == u8 or T.UserType == i8) {
        try reader.readNoEof(@bitCast([]u8, data));
    } else {
        for (data) |*elem| elem.* = try T.read(reader);
    }
}
pub fn readArrayAlloc(
    comptime T: type,
    alloc: Allocator,
    data: []T.UserType,
    reader: anytype,
) !void {
    for (data) |*elem, i| {
        if (@hasDecl(T, "readAlloc")) {
            errdefer {
                var ind: usize = 0;
                while (ind < i) : (ind += 1) {
                    T.deinit(data[ind], alloc);
                }
            }
            elem.* = try T.readAlloc(alloc, reader);
        } else {
            elem.* = try T.read(reader);
        }
    }
}
pub fn skipArray(comptime T: type, reader: anytype, len: usize) !void {
    if (@hasDecl(T, "Size")) {
        const total_bytes = T.Size * len;
        try reader.skipBytes(total_bytes, .{ .buf_size = 128 });
    } else {
        var i: usize = 0;
        while (i < len) : (i += 1) try T.skip(reader);
    }
}
pub fn sizeArray(comptime T: type, arr: []const T.UserType) usize {
    if (@hasDecl(T, "Size")) {
        return T.Size * arr.len;
    } else {
        var total_size: usize = 0;
        for (arr) |elem| {
            total_size += T.size(elem);
        }
        return total_size;
    }
}

pub const StaticArrayError = error{IncorrectLength};
pub fn StaticArray(
    comptime elementType: type,
    comptime array_len: comptime_int,
) type {
    assert(isSerializable(elementType));
    return struct {
        pub const ElementType = elementType;
        pub const UserType = [array_len]ElementType.UserType;
        pub const SerdeName = .StaticArray;

        pub fn getPrefix(self: UserType) usize {
            _ = self;
            return array_len;
        }
        pub fn write(self: UserType, writer: anytype) !void {
            try writeArray(ElementType, &self, writer);
        }
        pub fn size(self: UserType) usize {
            return sizeArray(ElementType, &self);
        }

        usingnamespace if (@hasDecl(ElementType, "readAlloc")) struct {
            pub const read = @compileError("May allocate");
            pub fn readAlloc(alloc: Allocator, reader: anytype, len: usize) !UserType {
                if (len != array_len) return error.IncorrectLength;
                var self: UserType = undefined;
                try readArrayAlloc(ElementType, alloc, &self, reader);
                return self;
            }
            pub fn deinit(self: UserType, alloc: Allocator) void {
                var i: usize = array_len;
                while (i > 0) {
                    i -= 1;
                    ElementType.deinit(self[i], alloc);
                }
            }
            pub fn skip(reader: anytype, len: usize) !void {
                if (len != array_len) return error.IncorrectLength;
                try skipArray(ElementType, reader, len);
            }
        } else struct {
            pub fn read(reader: anytype, len: usize) !UserType {
                if (len != array_len) return error.IncorrectLength;
                var self: UserType = undefined;
                try readArray(ElementType, &self, reader);
                return self;
            }
        };
    };
}
// i was going to call it a BoundedArray but then i remembered `std.BoundedArray` is already
// a thing
pub fn LimitedArray(
    comptime elementType: type,
    comptime max: comptime_int,
) type {
    assert(isSerializable(elementType));
    return struct {
        pub const ElementType = elementType;
        pub const UserType = std.BoundedArray(ElementType.UserType, max);
        pub const SerdeName = .LimitedArray;

        pub fn getPrefix(self: UserType) usize {
            return self.len;
        }
        pub fn write(self: UserType, writer: anytype) !void {
            try writeArray(ElementType, self.slice(), writer);
        }
        pub fn size(self: UserType) usize {
            return sizeArray(ElementType, self.slice());
        }

        usingnamespace if (@hasDecl(ElementType, "readAlloc")) struct {
            pub const read = @compileError("May allocate");

            pub fn readAlloc(alloc: Allocator, reader: anytype, len: usize) !UserType {
                var self = try UserType.init(len);
                try readArrayAlloc(ElementType, alloc, self.slice(), reader);
                return self;
            }
            pub fn deinit(self: UserType, alloc: Allocator) void {
                var i: usize = self.len;
                while (i > 0) {
                    i -= 1;
                    ElementType.deinit(self.buffer[i], alloc);
                }
            }
            pub fn skip(reader: anytype, len: usize) !void {
                try skipArray(ElementType, reader, len);
            }
        } else struct {
            pub fn read(reader: anytype, len: usize) !UserType {
                var self = try UserType.init(len);
                try readArray(ElementType, self.slice(), reader);
                return self;
            }
        };
    };
}
/// heap allocated array, requires a length
pub fn DynamicArray(comptime elementType: type) type {
    assert(isSerializable(elementType));
    return struct {
        pub const ElementType = elementType;
        pub const UserType = []const ElementType.UserType;
        pub const SerdeName = .DynamicArray;

        pub fn getPrefix(self: UserType) usize {
            return self.len;
        }
        pub fn write(self: UserType, writer: anytype) !void {
            try writeArray(ElementType, self, writer);
        }
        pub fn size(self: UserType) usize {
            return sizeArray(ElementType, self);
        }

        pub const read = @compileError("May allocate");

        pub fn readAlloc(alloc: Allocator, reader: anytype, len: usize) !UserType {
            var data = try alloc.alloc(ElementType.UserType, len);
            errdefer alloc.free(data);
            if (@hasDecl(ElementType, "readAlloc")) {
                try readArrayAlloc(ElementType, alloc, data, reader);
            } else {
                try readArray(ElementType, data, reader);
            }
            return data;
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
            if (@hasDecl(ElementType, "readAlloc")) {
                var i: usize = self.len;
                while (i > 0) {
                    i -= 1;
                    ElementType.deinit(self[i], alloc);
                }
            }
            alloc.free(self);
        }
        pub fn skip(reader: anytype, len: usize) !void {
            try skipArray(ElementType, reader, len);
        }
    };
}

pub fn PrefixedArray(
    comptime UsedSpec: type,
    comptime PartialLength: type,
    comptime PartialElement: type,
) type {
    const Length = UsedSpec.Spec(PartialLength, PartialLength);
    const Element = UsedSpec.Spec(PartialElement, PartialElement);
    return Prefixed(IntRestricted(Length, usize, .{}), DynamicArray(Element));
}

/// reads a utf8 string where the provided length is the number of codepoints (not number of bytes).
pub const CodepointArray = struct {
    pub const UserType = []const u8;
    pub const SerdeName = .VariableLengthElementArray;

    pub const Stepped = struct {
        index: usize = 0,
        len: usize,
        const Self = @This();
        pub fn init(len: usize) Self {
            return .{
                .len = len,
            };
        }
        pub fn next(self: *Self, reader: anytype) !?std.BoundedArray(u8, 4) {
            if (self.index >= self.len) return null;
            self.index += 1;
            var data = std.BoundedArray(u8, 4){};
            data.buffer[0] = try reader.readByte();
            const codepoint_len = try unicode.utf8ByteSequenceLength(data.buffer[0]);
            if (codepoint_len > 0) {
                try reader.readNoEof(data.buffer[1..codepoint_len]);
            }
            data.len = codepoint_len;
            return data;
        }
    };

    pub fn getPrefix(self: UserType) usize {
        // *should* be valid utf8 codepoints? any error should be found during read?
        return unicode.utf8CountCodepoints(self) catch unreachable;
    }
    pub fn write(self: UserType, writer: anytype) !void {
        try writer.writeAll(self);
    }
    pub fn size(self: UserType) usize {
        return self.len;
    }

    pub const read = @compileError("Use allocation");

    pub fn readAlloc(alloc: Allocator, reader: anytype, len: usize) !UserType {
        var data = try std.ArrayList(u8).initCapacity(alloc, len);
        defer data.deinit();
        var iter = Stepped.init(len);
        while (try iter.next(reader)) |codepoint| {
            try data.appendSlice(codepoint.slice());
        }
        return data.toOwnedSlice();
    }
    pub fn deinit(self: UserType, alloc: Allocator) void {
        alloc.free(self);
    }

    pub fn skip(reader: anytype, len: usize) !UserType {
        var iter = Stepped.init(len);
        while (try iter.next(reader)) |_| {}
    }
};

/// optional type. represents when there may or may not be more data. potential data is
/// prefixed with a boolean. if boolean is true, there is data after
pub fn Optional(comptime UsedSpec: type, comptime T: type, comptime userType: type) type {
    return struct {
        pub const InnerType = UsedSpec.Spec(@typeInfo(T).Optional.child);
        //pub const UserType = ?InnerType.UserType;
        pub const UserType = userType;
        pub const SerdeName = .Optional;

        pub fn write(self: UserType, writer: anytype) !void {
            try Bool.write(self != null, writer);
            if (self) |inner| {
                try InnerType.write(inner, writer);
            }
        }
        pub fn size(self: UserType) usize {
            if (self) |inner| {
                return 1 + InnerType.size(inner);
            }
            return 1;
        }
        usingnamespace if (@hasDecl(InnerType, "readAlloc")) struct {
            pub const read = @compileError("May allocate");

            pub fn readAlloc(alloc: Allocator, reader: anytype) !UserType {
                if (try Bool.read(reader)) {
                    return try InnerType.readAlloc(alloc, reader);
                }
                return null;
            }
            pub fn deinit(self: UserType, alloc: Allocator) void {
                if (self) |inner| {
                    InnerType.deinit(inner, alloc);
                }
            }
            pub fn skip(reader: anytype) !void {
                if (try Bool.read(reader)) {
                    try noRead(InnerType, reader);
                }
            }
        } else struct {
            pub fn read(reader: anytype) !UserType {
                if (try Bool.read(reader)) {
                    return try InnerType.read(reader);
                }
                return null;
            }
        };
    };
}

/// gets an enum of the fields of a type. if a type has a "Name" declaration, then it uses
/// that instead. mostly copied from std.meta.FieldEnum
pub fn NameEnum(comptime T: type, comptime Specs: []const type) type {
    const field_infos = meta.fields(T);
    var enumFields: [field_infos.len]std.builtin.Type.EnumField = undefined;
    var decls = [_]std.builtin.Type.Declaration{};
    inline for (field_infos) |field, i| {
        enumFields[i] = .{
            .name = if (@hasDecl(Specs[i], "Name")) Specs[i].Name else field.name,
            .value = i,
        };
    }
    return @Type(.{
        .Enum = .{
            .layout = .Auto,
            .tag_type = if (field_infos.len == 0) u0 else std.math.IntFittingRange(0, field_infos.len - 1),
            .fields = &enumFields,
            .decls = &decls,
            .is_exhaustive = true,
        },
    });
}

pub fn StructBuilder(
    comptime UserType: type,
    comptime Specs: anytype,
    comptime uses_alloc: bool,
) type {
    const user_fields = @typeInfo(UserType).Struct.fields;
    const names = NameEnum(UserType, Specs);
    return struct {
        data: UserType = blk: {
            var data: UserType = undefined;
            inline for (user_fields) |field| {
                if (@typeInfo(field.field_type) == .Optional) {
                    @field(data, field.name) = null;
                }
            }
            break :blk data;
        },
        null_fields: std.StaticBitSet(user_fields.len) = blk: {
            var null_fields = std.StaticBitSet(user_fields.len).initEmpty();
            inline for (user_fields) |field, i| {
                if (@typeInfo(field.field_type) == .Optional) {
                    null_fields.setValue(@as(usize, i), true);
                }
            }
            break :blk null_fields;
        },
        written_fields: std.StaticBitSet(user_fields.len) = std.StaticBitSet(user_fields.len).initEmpty(),

        const Self = @This();

        usingnamespace if (uses_alloc) struct {
            pub const setField = @compileError("use setFieldAlloc");

            pub fn setFieldAlloc(
                self: *Self,
                alloc: Allocator,
                reader: anytype,
                name: []const u8,
                args: anytype,
            ) !void {
                const field_ind: usize = @enumToInt(meta.stringToEnum(names, name) orelse {
                    return error.UnexpectedField;
                });
                if (self.written_fields.isSet(field_ind)) return error.DuplicateField;
                blk: {
                    const opts = std.builtin.CallOptions{};
                    inline for (user_fields) |field, i| if (i == field_ind) {
                        const res = if (@hasDecl(Specs[i], "readAlloc"))
                            @call(opts, Specs[i].readAlloc, .{ alloc, reader } ++ args)
                        else
                            @call(opts, Specs[i].read, .{reader} ++ args);
                        if (meta.isError(res)) _ = res catch |err| return err;
                        // note: not our job to deinit on failure here
                        const val = res catch unreachable;
                        @field(self.data, field.name) = val;
                        break :blk;
                    };
                    unreachable;
                }
                self.null_fields.setValue(@intCast(usize, field_ind), true);
                self.written_fields.setValue(@intCast(usize, field_ind), true);
            }
            pub fn deinit(self: *Self, alloc: Allocator) void {
                inline for (user_fields) |field, i| if (@hasDecl(Specs[i], "readAlloc")) {
                    if (self.written_fields.isSet(i)) {
                        Specs[i].deinit(@field(self.data, field.name), alloc);
                    }
                };
            }
        } else struct {
            pub fn setField(
                self: *Self,
                reader: anytype,
                name: []const u8,
                args: anytype,
            ) !void {
                const field_ind: usize = @enumToInt(meta.stringToEnum(names, name) orelse {
                    return error.UnexpectedField;
                });
                if (self.written_fields.isSet(field_ind)) return error.DuplicateField;
                blk: {
                    const opts = std.builtin.CallOptions{}; // not sure why, but this needs
                    // to be a separate variable
                    inline for (user_fields) |field, i| if (i == field_ind) {
                        const res = @call(opts, Specs[i].read, .{reader} ++ args);
                        if (meta.isError(res)) _ = res catch |err| return err;
                        const val = res catch unreachable;
                        @field(self.data, field.name) = val;
                        break :blk;
                    };
                    unreachable;
                }
                self.null_fields.setValue(@intCast(usize, field_ind), true);
                self.written_fields.setValue(@intCast(usize, field_ind), true);
            }
        };
        pub fn skipField(
            self: *Self,
            reader: anytype,
            name: []const u8,
            args: anytype,
        ) !void {
            const field_ind: usize = @enumToInt(meta.stringToEnum(names, name) orelse {
                return error.UnexpectedField;
            });
            if (self.written_fields.isSet(field_ind)) return error.DuplicateField;
            blk: {
                const opts = std.builtin.CallOptions{};
                inline for (user_fields) |_, i| if (i == field_ind) {
                    const res = if (@hasDecl(Specs[i], "readAlloc"))
                        @call(opts, Specs[i].skip, .{reader} ++ args)
                    else
                        @call(opts, Specs[i].read, .{reader} ++ args);
                    if (meta.isError(res)) _ = res catch |err| return err;
                    break :blk;
                };
                unreachable;
            }
            self.null_fields.setValue(@intCast(usize, field_ind), true);
            self.written_fields.setValue(@intCast(usize, field_ind), true);
        }
        pub fn done(self: Self) !UserType {
            // debug errdefer
            errdefer inline for (user_fields) |field, i| if (!self.null_fields.isSet(i)) {
                const name = if (@hasDecl(Specs[i], "Name")) Specs[i].Name else field.name;
                std.log.info("missing \"{s}\"", .{name});
            };
            if (self.fields_with_data.count() < Specs.len) return error.InsufficientFields;
            return self.data;
        }
    };
}

/// takes a packed struct and directly reads and writes it
pub fn Packed(comptime T: type) type {
    // TODO: test this on a non-little endian system?
    return struct {
        pub const UserType = T;
        pub const Size = @sizeOf(UserType);
        pub fn write(self: UserType, writer: anytype) !void {
            try writer.writeStruct(self);
        }
        pub fn read(reader: anytype) !UserType {
            return reader.readStruct(UserType);
        }
        pub fn size(self: UserType) usize {
            _ = self;
            return Size;
        }
    };
}

/// reads elements until end of stream
pub fn Remaining(comptime Element: type) type {
    assert(isSerializable(Element));
    return struct {
        const dynarr = DynamicArray(Element);
        pub const ElementType = dynarr.ElementType;
        pub const UserType = dynarr.UserType;

        pub fn write(self: UserType, writer: anytype) !void {
            try dynarr.write(self, writer);
        }
        pub fn size(self: UserType) usize {
            return dynarr.size(self);
        }
        pub const read = @compileError("May allocate");

        pub fn readAlloc(alloc: Allocator, reader: anytype) !UserType {
            var data = std.ArrayList(ElementType.UserType).init(alloc);
            defer data.deinit();
            if (ElementType.UserType == u8 or ElementType.UserType == i8) {
                var buf: [512]u8 = undefined;
                while (true) {
                    const len = try reader.read(&buf);
                    if (len == 0) break;
                    try data.appendSlice(@bitCast([]ElementType.UserType, buf[0..len]));
                }
            } else {
                while (true) {
                    if (@hasDecl(ElementType, "readAlloc")) {
                        errdefer {
                            var ind: usize = data.items.len;
                            while (ind > 0) {
                                ind -= 1;
                                ElementType.deinit(data[ind], alloc);
                            }
                        }
                        var elem = ElementType.readAlloc(alloc, reader) catch |e| {
                            if (e == error.EndOfStream) break else return e;
                        };
                        errdefer ElementType.deinit(elem, alloc);
                        try data.append(elem);
                    } else {
                        try data.append(ElementType.read(reader) catch |e| {
                            if (e == error.EndOfStream) break else return e;
                        });
                    }
                }
            }
            return data.toOwnedSlice();
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
            dynarr.deinit(self, alloc);
        }
        pub fn skip(reader: anytype) !void {
            var buf: [512]u8 = undefined;
            while ((try reader.read(&buf)) != 0) {}
        }
    };
}

test "bare struct, num" {
    const Partial = struct {
        a: u8,
        b: u16,
        c: struct {
            d: u32,
            e: u64,
        },
    };
    const UserType = GetUserType(Partial);
    const DataSerde = bare.Spec(Partial, UserType);
    const data = [_]u8{ 5, 0, 10, 0, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0, 128 };
    var stream = std.io.fixedBufferStream(&data);
    const result = try DataSerde.read(stream.reader());
    try testing.expect(meta.eql(UserType{
        .a = 5,
        .b = 10,
        .c = .{
            .d = 20,
            .e = 128,
        },
    }, result));
    try testing.expectEqual(data.len, DataSerde.size(result));
    try testing.expectEqual(data.len, DataSerde.Size);
}

test "serde prefixed array" {
    const SpecType = PrefixedArray(bare, u8, u16);

    const buf = [_]u8{
        // len
        0x04,
        // 0
        0x00,
        0x01,
        // 1
        0x02,
        0x01,
        // 2
        0x08,
        0x10,
        // 3
        0x00,
        0x02,
    };
    var reader = std.io.fixedBufferStream(&buf);
    const result = try SpecType.readAlloc(testing.allocator, reader.reader());
    defer SpecType.deinit(result, testing.allocator);
    try testing.expectEqualSlices(u16, &[_]u16{ 0x0001, 0x0201, 0x0810, 0x0002 }, result);
    try testing.expectEqual(buf.len, SpecType.size(result));

    var wrote_data = std.ArrayList(u8).init(testing.allocator);
    defer wrote_data.deinit();
    try SpecType.write(result, wrote_data.writer());
    try testing.expectEqualSlices(u8, &buf, wrote_data.items);
}

test "serde tagged union" {
    const TestEnum = enum(u8) {
        A = 0,
        B = 1,
        C = 2,
        D = 4,
    };
    const TestUnion = union(TestEnum) {
        A: u8,
        B: u16,
        C: void,
        D: struct {
            a: i32,
            b: bool,
        },
    };
    const UserType = GetUserType(TestUnion);
    const SerdeUnion = TaggedUnion(bare, u8, TestUnion, UserType);
    inline for (.{
        .{ .buf = [_]u8{ 0x00, 0x05 }, .desired = SerdeUnion.UserType{ .A = 5 } },
        .{ .buf = [_]u8{ 0x01, 0x01, 0x00 }, .desired = SerdeUnion.UserType{ .B = 256 } },
        .{ .buf = [_]u8{0x02}, .desired = SerdeUnion.UserType.C },
        .{ .buf = [_]u8{ 0x04, 0x00, 0x00, 0x00, 0x08, 0x01 }, .desired = SerdeUnion.UserType{
            .D = .{ .a = 8, .b = true },
        } },
    }) |pair| {
        var stream = std.io.fixedBufferStream(&pair.buf);
        const result = try SerdeUnion.read(stream.reader());
        try testing.expect(meta.eql(result, pair.desired));
    }
}

test "packed spec" {
    const TestStruct = Packed(packed struct {
        a: bool,
        b: bool,
        c: bool,
        d: bool,
        e: bool,
        f: bool,
    });
    // 0b11010000 -> 0xD0
    //       4321
    const buf = [_]u8{0xD0};
    var stream = std.io.fixedBufferStream(&buf);
    const result = try TestStruct.read(stream.reader());
    try testing.expect(meta.eql(result, .{
        .a = false,
        .b = false,
        .c = false,
        .d = false,
        .e = true,
        .f = false,
    }));
}

test "serde remaining" {
    const Partial = struct {
        a: i32,
        data: Remaining(bare.Spec(u8, u8)),
    }; // TODO: into shit
    const UserType = GetUserType(Partial);
    const SpecType = bare.Spec(Partial, UserType);

    const buf = [_]u8{ 0x00, 0x00, 0x01, 0x02, 0x01, 0x08, 0x10, 0x00, 0x02 };
    var reader = std.io.fixedBufferStream(&buf);
    const result = try SpecType.readAlloc(testing.allocator, reader.reader());
    defer SpecType.deinit(result, testing.allocator);
    try testing.expectEqual(@as(i32, 258), result.a);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x08, 0x10, 0x00, 0x02 }, result.data);
    try testing.expectEqual(buf.len, SpecType.size(result));
}
