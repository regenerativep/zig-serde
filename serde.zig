const std = @import("std");
const meta = std.meta;
const assert = std.debug.assert;
const testing = std.testing;
const builtin = std.builtin;
const unicode = std.unicode;
const Allocator = std.mem.Allocator;

/// basic void serialization type.
/// basically just doesnt do anything
pub const Void = struct {
    pub const UserType = void;
    pub const Stepped = void;
    pub const Size = 0;
    pub fn write(self: UserType, writer: anytype) !void {
        _ = self;
        _ = writer;
    }
    pub fn read(reader: anytype) !UserType {
        _ = reader;
    }
    pub fn readRest(reader: anytype) !void {
        _ = reader;
    }
    pub fn size(self: UserType) usize {
        _ = self;
        return Size;
    }
};

/// number serialization type for any int or float with specified endianness
pub fn Num(comptime T: type, endian: std.builtin.Endian) type {
    const info = @typeInfo(T);
    if (info != .Int and info != .Float) {
        @compileError("expected an int or a float");
    }
    return struct {
        const IntType = if (info == .Float) meta.Int(.unsigned, info.Float.bits) else T;
        pub const UserType = T;
        pub const Size = @sizeOf(T);
        pub fn write(self: UserType, writer: anytype) !void {
            try writer.writeInt(IntType, @bitCast(IntType, self), endian);
        }
        pub fn read(reader: anytype) !UserType {
            const val = try reader.readInt(IntType, endian);
            return @bitCast(T, val);
        }
        pub fn readRest(reader: anytype) !void {
            _ = try read(reader);
        }
        pub fn size(self: UserType) usize {
            _ = self;
            return Size;
        }
    };
}

/// bool serialization type. serialized as a single byte, true => 0x01 or => 0x00
/// currently implemented where read byte != 0x01 => false, else true
pub const Bool = struct {
    pub const UserType = bool;
    pub const Size = 1;
    pub fn write(self: UserType, writer: anytype) !void {
        try writer.writeByte(if (self) 0x01 else 0x00);
    }
    pub fn read(reader: anytype) !UserType {
        return (try reader.readByte()) == 0x01;
    }
    pub fn deinit(self: UserType, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
    pub fn readRest(reader: anytype) !void {
        _ = try reader.readByte();
    }
    pub fn size(self: UserType) usize {
        _ = self;
        return Size;
    }
};

/// calls UsedSpec.Spec on each field type of Partial and puts it into a list
pub fn fieldSpecs(comptime UsedSpec: type, comptime Partial: type) [meta.fields(Partial).len]type {
    const fields = meta.fields(Partial);
    var specs: [fields.len]type = undefined;
    inline for (fields) |field, i| {
        const SpecType = UsedSpec.Spec(field.field_type);
        specs[i] = SpecType;
    }
    return specs;
}

/// preforms the equivalent to a readRest call on a serialization type, but accounts
/// for when type has no readRest function and does not allocate
pub fn noRead(comptime Spec: type, reader: anytype) !void {
    if (@hasDecl(Spec, "readAlloc")) {
        try Spec.readRest(reader);
    } else {
        _ = try Spec.read(reader);
    }
}

/// version of deserialization for structs to give the user more control over
/// exactly how it deserializes
pub fn SteppedStruct(comptime Partial: type, comptime Specs: []const type) type {
    if (Specs.len == 0) return void;
    comptime var steps = [_]type{undefined} ** Specs.len;
    comptime var i = Specs.len;
    inline while (i > 0) {
        i -= 1;
        steps[i] = makeStep(i, steps[i + 1 ..], Partial, Specs);
    }
    return steps[0];
}
// function required to avoid https://github.com/ziglang/zig/issues/10029
pub fn makeStep(
    comptime i: comptime_int,
    comptime remaining_steps: []const type,
    comptime Partial: type,
    comptime Specs: []const type,
) type {
    const info = @typeInfo(Partial).Struct;
    return struct {
        pub const Index = i;
        pub const Steps = remaining_steps;
        pub const Next = if (i == Specs.len - 1) void else Steps[0];
        pub const Type = Specs[i];

        pub fn GetType(comptime name: []const u8) type {
            const ind = meta.fieldIndex(Partial, name) orelse @compileError("No field by name \"" ++ name ++ "\"");
            const val = if (ind == i) @This() else Steps[ind - (i + 1)];
            assert(val.Index == ind);
            return val;
        }
        // returns a zero sized type so that we can return an error
        pub fn goUntil(reader: anytype, comptime name: []const u8) !GetType(name) {
            const ReturnType = GetType(name);
            if (comptime std.mem.eql(u8, info.fields[i].name, name)) return ReturnType{};
            comptime var j = i + 1;
            inline while (j < Specs.len) : (j += 1) {
                if (comptime std.mem.eql(u8, info.fields[j].name, name)) {
                    return ReturnType{};
                } else {
                    try noRead(Specs[j], reader);
                }
            }
            @compileError("Could not find field \"" ++ name ++ "\" after current field");
        }

        pub fn done(reader: anytype) !void {
            comptime var j = i + 1;
            inline while (j < Specs.len) : (j += 1) {
                try noRead(Specs[j], reader);
            }
        }
    };
}

/// generates the user type given a struct's specs
pub fn StructUserType(comptime Partial: type, comptime Specs: []const type) type {
    const info = @typeInfo(Partial).Struct;
    var fields: [info.fields.len]builtin.TypeInfo.StructField = undefined;
    inline for (info.fields) |*field, i| {
        var f = field.*;
        f.field_type = Specs[i].UserType;
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

/// checks if the provided specs use allocation
pub fn SpecsUseAllocation(comptime Specs: []const type) bool {
    inline for (Specs) |spec| {
        if (@hasDecl(spec, "readAlloc")) {
            return true;
        }
    }
    return false;
}

/// checks if the provided specs are all constant size, and if so, what constant size
pub fn ConstantStructSize(comptime Specs: []const type) ?comptime_int {
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

/// serialization type for structs
/// will figure out which deserialization functions to use based on the discovered specs
pub fn Struct(comptime UsedSpec: type, comptime Partial: type) type {
    const info = @typeInfo(Partial).Struct;

    return struct {
        pub const Specs = fieldSpecs(UsedSpec, Partial);
        pub const UserType = StructUserType(Partial, std.mem.span(&Specs));
        pub const Stepped = SteppedStruct(Partial, std.mem.span(&Specs));
        usingnamespace if (ConstantStructSize(std.mem.span(&Specs))) |constant_size| struct {
            pub const Size = constant_size;
        } else struct {};
        const Self = @This();

        pub fn write(self: anytype, writer: anytype) !void {
            inline for (info.fields) |field, i| {
                try Specs[i].write(@field(self, field.name), writer);
            }
        }
        usingnamespace if (SpecsUseAllocation(std.mem.span(&Specs))) struct {
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
        pub fn size(self: anytype) usize {
            if (@hasDecl(UserType, "Size")) {
                return Self.Size;
            } else {
                var total_size: usize = 0;
                inline for (info.fields) |field, i| {
                    total_size += Specs[i].size(@field(self, field.name));
                }
                return total_size;
            }
        }

        pub fn readRest(reader: anytype) !void {
            if (@hasDecl(UserType, "Size")) {
                try reader.skipBytes(Self.Size, .{ .buf_size = comptime std.math.min(Self.Size, 128) });
            } else {
                inline for (Specs) |spec| {
                    try noRead(spec, reader);
                }
            }
        }
    };
}

test "struct and stepped" {
    const DataType = Struct(DefaultSpec, struct {
        a: u8,
        b: u16,
        c: u32,
    });

    const data = [_]u8{ 5, 0, 10, 0, 0, 0, 20 };
    var stream = std.io.fixedBufferStream(&data);
    const result = try DataType.read(stream.reader());
    try testing.expect(result.a == 5);
    try testing.expect(result.b == 10);
    try testing.expect(result.c == 20);
    try testing.expectEqual(data.len, DataType.size(result));
    try testing.expectEqual(data.len, DataType.Size);

    stream.reset();
    var reader = stream.reader();

    //const A = DataType.Stepped.GetType("a");
    const A = @TypeOf(try DataType.Stepped.goUntil(reader, "a"));
    try testing.expect((try A.Type.read(reader)) == 5);

    const B = @TypeOf(try A.goUntil(reader, "b"));
    try testing.expect((try B.Type.read(reader)) == 10);

    const C = @TypeOf(try B.goUntil(reader, "c"));
    try testing.expect((try C.Type.read(reader)) == 20);

    try C.done(reader);
}

/// checks if the provided type is a serializable type
pub fn isSerializable(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .Struct and info != .Union and info != .Enum) return false;
    inline for (.{ "write", "read", "size", "UserType" }) |name| {
        if (!@hasDecl(T, name)) return false;
    }
    return true;
}

/// default method to turn a zig type into a version with de/serialization functions
pub const DefaultSpec = struct {
    pub fn Spec(comptime Partial: type) type {
        if (isSerializable(Partial)) return Partial; // already a serializable type
        switch (@typeInfo(Partial)) {
            .Struct => return Struct(DefaultSpec, Partial),
            .Void => return Void,
            .Bool => return Bool,
            .Int => return Num(Partial, .Big),
            .Float => return Num(Partial, .Big),
            .Enum => return Enum(@This(), meta.Tag(Partial), Partial),
            else => unreachable,
        }
    }
    pub fn IntegerSpec(comptime Partial: type) type {
        if (isSerializable(Partial) and @typeInfo(Partial.UserType) == .Int) return Partial;
        switch (@typeInfo(Partial)) {
            .Int => return Num(Partial, .Big),
            else => unreachable,
        }
    }
    pub fn IntegerRecipientSpec(comptime Partial: type) type {
        // TODO: can we check for specific argument types in one of Partial's functions?
        if (isSerializable(Partial)) return Partial;
        switch (@typeInfo(Partial)) {
            .Union => return Union(@This(), Partial),
            else => unreachable,
        }
    }
};

/// asserts that the provided type is already serializable (perform no conversion)
pub const NoSpec = struct {
    pub fn Spec(comptime Partial: type) type {
        if (isSerializable(Partial)) return Partial;
        unreachable;
    }
    pub fn IntegerSpec(comptime Partial: type) type {
        if (isSerializable(Partial) and @typeInfo(Partial.UserType) == .Int) return Partial;
        unreachable;
    }
    pub fn IntegerRecipientSpec(comptime Partial: type) type {
        if (isSerializable(Partial)) return Partial;
        unreachable;
    }
};

pub const StructBuilderError = error{
    UnexpectedField,
    DuplicateField,
    InsufficientFields,
};

/// gets an enum of the fields of a type. if a type has a "Name" declaration, then it uses that instead
/// mostly copied from std.meta.FieldEnum
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
            .tag_type = std.math.IntFittingRange(0, field_infos.len - 1),
            .fields = &enumFields,
            .decls = &decls,
            .is_exhaustive = true,
        },
    });
}

/// assists in writing the fields of a struct, especially when they may be read in
/// any order. keeps track on what fields are written, and which are optional and
/// dont need to be written to in order to complete the struct
pub fn StructBuilder(
    comptime T: type,
    comptime Specs: []const type,
    comptime uses_alloc: bool,
) type {
    // T is user type
    const fields = @typeInfo(T).Struct.fields;
    const FieldEnum = NameEnum(T, Specs);
    return struct {
        data: T = blk: {
            var data: T = undefined;
            inline for (fields) |field| {
                if (@typeInfo(field.field_type) == .Optional) {
                    @field(data, field.name) = null;
                }
            }
            break :blk data;
        },
        fields_with_data: std.StaticBitSet(fields.len) = blk: {
            var fields_with_data = std.StaticBitSet(Specs.len).initEmpty();
            inline for (fields) |field, i| {
                if (@typeInfo(field.field_type) == .Optional) {
                    fields_with_data.setValue(@as(usize, i), true);
                }
            }
            break :blk fields_with_data;
        },
        written_fields: std.StaticBitSet(fields.len) = std.StaticBitSet(fields.len).initEmpty(),

        const Self = @This();

        usingnamespace if (uses_alloc) struct {
            pub const setField = @compileError("use setFieldAlloc");

            pub fn setFieldAlloc(self: *Self, alloc: Allocator, reader: anytype, name: []const u8) !void {
                const field_ind = @enumToInt(meta.stringToEnum(FieldEnum, name) orelse return error.UnexpectedField);
                if (self.written_fields.isSet(@intCast(usize, field_ind))) {
                    return error.DuplicateField;
                }
                blk: {
                    // use inline for to find and use corresponding Specs type to deserialize
                    inline for (fields) |field, i| {
                        if (i == field_ind) {
                            const res = if (@hasDecl(Specs[i], "readAlloc")) Specs[i].readAlloc(alloc, reader) else Specs[i].read(reader);
                            if (meta.isError(res)) _ = res catch |err| return err;
                            // note: not our job to deinit on failure here
                            const val = res catch unreachable;
                            @field(self.data, field.name) = val;
                            break :blk;
                        }
                    }
                    unreachable;
                }
                // tell the bit sets that this field is "written to"
                self.fields_with_data.setValue(@intCast(usize, field_ind), true);
                self.written_fields.setValue(@intCast(usize, field_ind), true);
            }

            pub fn deinit(self: *Self, alloc: Allocator) void {
                inline for (fields) |field, i| {
                    if (@hasDecl(Specs[i], "readAlloc")) {
                        if (self.written_fields.isSet(i)) {
                            //const found_data = if (@typeInfo(field.field_type) == .Optional) @field(self.data, field.name).? else @field(self.data, field.name);
                            const found_data = @field(self.data, field.name);
                            Specs[i].deinit(found_data, alloc);
                        }
                    }
                }
            }
        } else struct {
            pub fn setField(
                self: *Self,
                reader: anytype,
                name: []const u8,
            ) !void {
                const field_ind = @enumToInt(meta.stringToEnum(FieldEnum, name) orelse return error.UnexpectedField);
                if (self.written_fields.isSet(@intCast(usize, field_ind))) {
                    return error.DuplicateField;
                }
                blk: {
                    inline for (fields) |field, i| {
                        if (i == field_ind) {
                            const res = Specs[i].read(reader);
                            if (meta.isError(res)) _ = res catch |err| return err;
                            const val = res catch unreachable;
                            @field(self.data, field.name) = val;
                            break :blk;
                        }
                    }
                    unreachable;
                }
                self.fields_with_data.setValue(@intCast(usize, field_ind), true);
                self.written_fields.setValue(@intCast(usize, field_ind), true);
            }
        };
        pub fn nosetField(self: *Self, reader: anytype, name: []const u8) !void {
            const field_ind = @enumToInt(meta.stringToEnum(FieldEnum, name) orelse return error.UnexpectedField);
            if (self.written_fields.isSet(@intCast(usize, field_ind))) {
                return error.DuplicateField;
            }
            blk: {
                inline for (fields) |_, i| {
                    if (i == field_ind) {
                        const res = noRead(Specs[i], reader);
                        if (meta.isError(res)) _ = res catch |err| return err;
                        break :blk;
                    }
                }
                unreachable;
            }
            self.fields_with_data.setValue(@intCast(usize, field_ind), true);
            self.written_fields.setValue(@intCast(usize, field_ind), true);
        }
        pub fn done(self: Self) !T {
            if (self.fields_with_data.count() < Specs.len) return error.InsufficientFields;
            return self.data;
        }
    };
}

/// reads an integer into an enum. UserType is the provided enum
pub fn Enum(
    comptime UsedSpec: type,
    comptime PartialTag: type,
    comptime UserType: type,
) type {
    assert(@typeInfo(UserType) == .Enum);
    return struct {
        pub const TagType = UsedSpec.Spec(PartialTag);
        usingnamespace if (@hasDecl(TagType, "Size")) struct {
            pub const Size = TagType.Size;
        } else struct {};
        comptime {
            assert(@typeInfo(TagType.UserType) == .Int);
            assert(!@hasDecl(TagType, "readAlloc"));
        }
        pub const UserType = UserType;
        pub fn getInt(self: UserType) TagType.UserType {
            return @intCast(TagType.UserType, @enumToInt(self));
        }
        pub fn write(self: UserType, writer: anytype) !void {
            try TagType.write(getInt(self), writer);
        }
        pub fn read(reader: anytype) !UserType {
            return try meta.intToEnum(UserType, try TagType.read(reader));
        }
        const Self = @This();
        pub fn readRest(reader: anytype) !void {
            if (@hasDecl(Self, "Size")) {
                try reader.skipBytes(Self.Size, .{ .buf_size = comptime std.math.min(Self.Size, 128) });
            } else {
                _ = try TagType.read(reader);
            }
        }
        pub fn size(self: UserType) usize {
            if (@hasDecl(Self, "Size")) {
                return Self.Size;
            } else {
                return TagType.size(getInt(self));
            }
        }
    };
}

/// generates union type using the specs user types
pub fn UnionUserType(comptime Partial: type, comptime Specs: []const type) type {
    const info = @typeInfo(Partial).Union;
    var fields: [info.fields.len]builtin.TypeInfo.UnionField = undefined;
    inline for (info.fields) |*field, i| {
        var f = field.*;
        f.field_type = Specs[i].UserType;
        fields[i] = f;
    }
    return @Type(builtin.TypeInfo{ .Union = .{
        .layout = info.layout,
        .tag_type = info.tag_type,
        .fields = &fields,
        .decls = &[_]std.builtin.TypeInfo.Declaration{},
    } });
}

/// if all union paths are the same constant size, then this returns the size
pub fn ConstantUnionSize(comptime Specs: []const type) ?comptime_int {
    comptime var first_size = if (@hasDecl(Specs[0], "Size")) Specs[0].Size else return null;
    inline for (Specs) |spec| if (!@hasDecl(spec, "Size") or spec.Size != first_size) return null;
    return first_size;
}

/// given something that may or may not be a serializable type, return the int
/// if it is not an int, then bad
pub fn GetIntType(comptime Partial: type) type {
    const result = if (isSerializable(Partial)) Partial.UserType else Partial;
    assert(@typeInfo(result) == .Int);
    return result;
}

/// union type. incompatible with normal serializable types since this takes in an extra argument
/// to figure out the tag. (pair this with something like IntegerPrefixed)
/// affects read, readAlloc, readRest
pub fn Union(comptime UsedSpec: type, comptime PartialUnion: type) type {
    assert(@typeInfo(PartialUnion) == .Union);
    return struct {
        pub const Specs = fieldSpecs(UsedSpec, PartialUnion);
        pub const UserType = UnionUserType(PartialUnion, std.mem.span(&Specs));
        pub const IntType = meta.Tag(meta.Tag(UserType));
        usingnamespace if (ConstantUnionSize(std.mem.span(&Specs))) |constant_size| struct {
            pub const Size = constant_size;
        } else struct {};
        pub const UserFields = meta.fields(UserType);
        const Self = @This();
        const field_enum = meta.FieldEnum(meta.Tag(UserType));

        pub fn getInt(self: anytype) IntType {
            const info = @typeInfo(@TypeOf(self));
            if (info == .Union) {
                return @intCast(IntType, @enumToInt(self));
            } else {
                assert(info == .Struct and info.Struct.fields.len == 1);
                return @intCast(IntType, @enumToInt(@field(meta.Tag(UserType), info.Struct.fields[0].name)));
            }
        }
        fn tagEnumField(comptime i: comptime_int) builtin.TypeInfo.EnumField { // TODO: surely these a less fancy way to do this
            return meta.fieldInfo(meta.Tag(UserType), @intToEnum(meta.FieldEnum(meta.Tag(UserType)), i));
        }
        pub fn write(self: anytype, writer: anytype) !void {
            const info = @typeInfo(@TypeOf(self));
            if (info == .Union) {
                const tag_int = getInt(self);
                inline for (UserFields) |field, i| {
                    const enum_field = tagEnumField(i);
                    if (enum_field.value == tag_int) {
                        const res = Specs[i].write(@field(self, field.name), writer);
                        if (meta.isError(res)) res catch |err| return err;
                        return;
                    }
                }
                return error.InvalidTag;
            } else {
                assert(info == .Struct and info.Struct.fields.len == 1);
                const name = info.Struct.fields[0].name;
                const i = @enumToInt(@field(field_enum, name));
                try Specs[i].write(@field(self, name), writer);
            }
        }
        usingnamespace if (SpecsUseAllocation(std.mem.span(&Specs))) struct {
            pub const read = @compileError("Requires allocation");

            pub fn readAlloc(alloc: Allocator, reader: anytype, tag_int: IntType) !UserType {
                inline for (UserFields) |field, i| {
                    const enum_field = tagEnumField(i);
                    if (enum_field.value == tag_int) {
                        // untested if this workaround is necessary for write, but it
                        // is necessary for deserialize https://github.com/ziglang/zig/issues/10087
                        const res = if (@hasDecl(Specs[i], "readAlloc")) Specs[i].readAlloc(alloc, reader) else Specs[i].read(reader);
                        if (meta.isError(res)) _ = res catch |err| return err;
                        const val = res catch unreachable;
                        return @unionInit(UserType, field.name, val);
                    }
                }
                return error.InvalidTag;
            }
            pub fn deinit(self: UserType, alloc: Allocator) void {
                const tag_int = getInt(self);
                inline for (UserFields) |field, i| {
                    _ = field;
                    //const enum_field = meta.fieldInfo(meta.Tag(UserType), @intToEnum(meta.FieldEnum(meta.Tag(UserType)), i));
                    const enum_field = tagEnumField(i);
                    if (enum_field.value == tag_int) {
                        if (@hasDecl(Specs[i], "readAlloc")) {
                            Specs[i].deinit(@field(self, field.name), alloc);
                        }
                        return;
                    }
                }
            }
        } else struct {
            pub fn read(reader: anytype, tag_int: IntType) !UserType {
                inline for (UserFields) |field, i| {
                    const enum_field = tagEnumField(i);
                    if (enum_field.value == tag_int) {
                        const res = Specs[i].read(reader);
                        if (meta.isError(res)) _ = res catch |err| return err;
                        const val = res catch unreachable;
                        return @unionInit(UserType, field.name, val);
                    }
                }
                return error.InvalidTag;
            }
        };
        pub fn size(self: anytype) usize {
            const info = @typeInfo(@TypeOf(self));
            if (info == .Union) {
                const tag_int = getInt(self);
                inline for (UserFields) |field, i| {
                    _ = field;
                    //const enum_field = meta.fieldInfo(meta.Tag(UserType), @intToEnum(meta.FieldEnum(meta.Tag(UserType)), i));
                    const enum_field = tagEnumField(i);
                    if (enum_field.value == tag_int) {
                        return Specs[i].size(@field(self, field.name));
                    }
                }
                return 0;
            } else {
                assert(info == .Struct and info.Struct.fields.len == 1);
                const name = info.Struct.fields[0].name;
                const i = @enumToInt(@field(field_enum, name));
                return Specs[i].size(@field(self, name));
            }
        }
        pub fn readRest(reader: anytype, tag_int: IntType) !void {
            if (@hasDecl(Self, "Size")) {
                try reader.skipBytes(Self.Size, .{ .max_len = comptime std.math.min(Self.Size, 128) });
            } else {
                inline for (UserFields) |_, i| {
                    const enum_field = tagEnumField(i);
                    if (enum_field.value == tag_int) {
                        const res = noRead(Specs[i], reader);
                        if (meta.isError(res)) _ = res catch |err| return err;
                        return;
                    }
                }
                return error.InvalidTag;
            }
        }
    };
}

/// convenience type to generate a tagged union using IntegerPrefixed and Union
pub fn TaggedUnion(
    comptime UsedSpec: type,
    comptime PartialTag: type,
    comptime PartialUnion: type,
) type {
    return IntegerPrefixed(UsedSpec, PartialTag, Union(UsedSpec, PartialUnion), .{});
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
    const SerdeUnion = TaggedUnion(DefaultSpec, u8, TestUnion);
    inline for (.{
        .{ .buf = [_]u8{ 0x00, 0x05 }, .desired = SerdeUnion.UserType{ .A = 5 } },
        .{ .buf = [_]u8{ 0x01, 0x01, 0x00 }, .desired = SerdeUnion.UserType{ .B = 256 } },
        .{ .buf = [_]u8{0x02}, .desired = SerdeUnion.UserType.C },
        .{ .buf = [_]u8{ 0x04, 0x00, 0x00, 0x00, 0x08, 0x01 }, .desired = SerdeUnion.UserType{ .D = .{ .a = 8, .b = true } } },
    }) |pair| {
        var stream = std.io.fixedBufferStream(&pair.buf);
        const result = try SerdeUnion.read(stream.reader());
        try testing.expect(meta.eql(result, pair.desired));
    }
}

/// takes a packed struct and directly reads and writes it
pub fn Packed(comptime T: type) type {
    // TODO: might not handle correctly on non-little-endian systems?
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

/// reads elements until end of stream
pub fn Remaining(comptime UsedSpec: type, comptime ElementTypePartial: type) type {
    return struct {
        const dynarr = DynamicArray(UsedSpec, ElementTypePartial);
        pub const ElementType = dynarr.ElementType;
        pub const UserType = dynarr.UserType;

        pub fn write(self: UserType, writer: anytype) !void {
            try dynarr.write(self, writer);
        }
        pub const read = @compileError("May use allocation");

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
        pub fn readRest(reader: anytype) !void {
            var buf: [512]u8 = undefined;
            while ((try reader.read(&buf)) != 0) {}
        }
        pub fn size(self: UserType) usize {
            return dynarr.size(self);
        }
    };
}

test "serde remaining" {
    const SpecType = DefaultSpec.Spec(struct {
        a: i32,
        data: Remaining(DefaultSpec, u8),
    });

    const buf = [_]u8{ 0x00, 0x00, 0x01, 0x02, 0x01, 0x08, 0x10, 0x00, 0x02 };
    var reader = std.io.fixedBufferStream(&buf);
    const result = try SpecType.readAlloc(testing.allocator, reader.reader());
    defer SpecType.deinit(result, testing.allocator);
    try testing.expectEqual(@as(i32, 258), result.a);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x08, 0x10, 0x00, 0x02 }, result.data);
    try testing.expectEqual(buf.len, SpecType.size(result));
}

pub const IntegerPrefixedOptions = struct {
    max: ?usize = null,
};

pub const CastError = error{CastFailure};
/// pairs with a type that requires an integer (like an array
/// that needs a length or a union that needs a tag). can specify a max value
/// for things like maximum length.
/// TODO: other options?
pub fn IntegerPrefixed(
    comptime UsedSpec: type,
    comptime LengthPartial: type,
    comptime SpecificPartial: type,
    comptime options: IntegerPrefixedOptions,
) type {
    return struct {
        pub const IntType = UsedSpec.IntegerSpec(LengthPartial);
        pub const IntTypeActual = GetIntType(IntType);
        pub const InnerType = UsedSpec.IntegerRecipientSpec(SpecificPartial);
        pub const InnerIntTypeActual = GetIntType(InnerType.IntType);
        pub const UserType = InnerType.UserType;
        pub const Error = if (options.max != null) error{PrefixedIntegerOutOfBounds} else error{};
        usingnamespace if (@hasDecl(IntType, "Size") and @hasDecl(InnerType, "Size")) struct {
            pub const Size = IntType.Size + InnerType.Size;
        } else struct {};

        pub fn write(self: anytype, writer: anytype) !void {
            const num = @intCast(IntTypeActual, InnerType.getInt(self));
            if (options.max) |max| if (num > max) return error.PrefixedIntegerOutOfBounds;
            try IntType.write(num, writer);
            try InnerType.write(self, writer);
        }
        usingnamespace if (@hasDecl(InnerType, "readAlloc")) struct {
            pub const read = @compileError("Requires allocation");

            pub fn readAlloc(alloc: Allocator, reader: anytype) !UserType {
                const num = std.math.cast(InnerIntTypeActual, try IntType.read(reader)) orelse return error.CastFailure;
                if (options.max) |max| if (num > max) return error.PrefixedIntegerOutOfBounds;
                return try InnerType.readAlloc(alloc, reader, num);
            }
            pub fn deinit(self: UserType, alloc: Allocator) void {
                InnerType.deinit(self, alloc);
            }
        } else struct {
            pub fn read(reader: anytype) !UserType {
                const num = std.math.cast(InnerIntTypeActual, try IntType.read(reader)) orelse return error.CastFailure;
                if (options.max) |max| if (num > max) return error.PrefixedIntegerOutOfBounds;
                return try InnerType.read(reader, num);
            }
        };
        pub fn size(self: anytype) usize {
            const num = @intCast(IntTypeActual, InnerType.getInt(self));
            if (options.max) |max| if (num > max) return error.PrefixedIntegerOutOfBounds;
            return IntType.size(num) + InnerType.size(self);
        }
        pub fn readRest(reader: anytype) !void {
            const num = std.math.cast(InnerIntTypeActual, try IntType.read(reader)) orelse return error.CastFailure;
            if (options.max) |max| if (num > max) return error.PrefixedIntegerOutOfBounds;
            try InnerType.readRest(reader, num);
        }
    };
}

/// generic prefix, not necessarily an integer. doesnt come with any fancy options
/// that are done with integers like in IntegerPrefixed.
pub fn Prefixed(comptime Prefix: type, comptime T: type) type {
    assert(isSerializable(Prefix));
    assert(isSerializable(T));
    return struct {
        pub const InnerType = T;
        pub const PrefixType = Prefix;
        pub const UserType = InnerType.UserType;
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
                InnerType.deinit(self.data, alloc);
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
        pub fn readRest(reader: anytype) !void {
            const prefix_data = try PrefixType.read(reader);
            try InnerType.readRest(reader, prefix_data);
        }
    };
}

/// heap allocated array, requires a length
pub fn DynamicArray(comptime UsedSpec: type, comptime ElementTypePartial: type) type {
    return struct {
        pub const ElementType = UsedSpec.Spec(ElementTypePartial);
        pub const UserType = []const ElementType.UserType;
        pub const IntType = usize;

        pub const Stepped = struct {
            index: usize = 0,
            len: usize,

            const Self = @This();
            pub fn init(len: usize) Self {
                return Self{
                    .len = len,
                };
            }
            usingnamespace if (@hasDecl(ElementType, "readAlloc")) struct {
                pub const next = @compileError("Element type may use allocation.");

                pub fn nextAlloc(self: *Self, alloc: Allocator, reader: anytype) !?ElementType.UserType {
                    if (self.index >= self.len) return null;
                    return try ElementType.readAlloc(alloc, reader);
                }
            } else struct {
                pub fn next(self: *Self, reader: anytype) !?ElementType.UserType {
                    if (self.index >= self.len) return null;
                    self.index += 1;
                    return try ElementType.read(reader);
                }
            };
        };

        pub fn write(self: UserType, writer: anytype) !void {
            if (ElementType.UserType == u8 or ElementType.UserType == i8 or ElementType.UserType == bool) {
                const data = @bitCast([]const u8, self);
                try writer.writeAll(data);
            } else {
                for (self) |elem| {
                    try ElementType.write(elem, writer);
                }
            }
        }

        pub fn getInt(self: anytype) usize {
            return self.len;
        }

        pub const read = @compileError("Use allocation");

        pub fn readAlloc(alloc: Allocator, reader: anytype, len: usize) !UserType {
            var data = try alloc.alloc(ElementType.UserType, len);
            errdefer alloc.free(data);
            if (ElementType.UserType == u8 or ElementType.UserType == i8) {
                try reader.readNoEof(@bitCast([]u8, data));
            } else {
                for (data) |*elem, i| {
                    if (@hasDecl(ElementType, "readAlloc")) {
                        errdefer {
                            var ind: usize = 0;
                            while (ind < i) : (ind += 1) {
                                ElementType.deinit(data[ind], alloc);
                            }
                        }
                        elem.* = try ElementType.readAlloc(alloc, reader);
                    } else {
                        elem.* = try ElementType.read(reader);
                    }
                }
            }
            return data;
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
            if (@hasDecl(ElementType, "readAlloc")) {
                for (self) |elem| {
                    ElementType.deinit(elem, alloc);
                }
            }
            alloc.free(self);
        }
        pub fn readRest(reader: anytype, len: usize) !void {
            if (@hasDecl(ElementType, "Size")) {
                const total_bytes = ElementType.Size * len;
                try reader.skipBytes(total_bytes, .{ .buf_size = 128 });
            } else {
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    try noRead(ElementType, reader);
                }
            }
        }
        pub fn size(self: UserType) usize {
            if (@hasDecl(ElementType, "Size")) {
                return ElementType.Size * self.len;
            } else {
                var total_size: usize = 0;
                for (self) |elem| {
                    total_size += ElementType.size(elem);
                }
                return total_size;
            }
        }
    };
}

/// convenience type for an integer prefixed dynamic array
pub fn PrefixedArray(
    comptime UsedSpec: type,
    comptime LengthPartial: type,
    comptime ElementPartial: type,
) type {
    return IntegerPrefixed(UsedSpec, LengthPartial, DynamicArray(UsedSpec, ElementPartial), .{});
}
/// convenience type for an integer prefixed dynamic array with a maximum length
pub fn PrefixedArrayMax(
    comptime UsedSpec: type,
    comptime LengthPartial: type,
    comptime ElementPartial: type,
    comptime max: comptime_int,
) type {
    return IntegerPrefixed(UsedSpec, LengthPartial, DynamicArray(UsedSpec, ElementPartial), .{ .max = max });
}

test "serde prefixed array" {
    const SpecType = PrefixedArray(DefaultSpec, u8, u16);

    const buf = [_]u8{
        0x04, // <-- length
        0x00, // beginning of data
        0x01,
        0x02,
        0x01,
        0x08,
        0x10,
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

    reader.reset();
    var stepped = SpecType.InnerType.Stepped.init(@intCast(usize, try SpecType.IntType.read(reader.reader())));
    inline for (.{ 0x0001, 0x0201, 0x0810, 0x0002 }) |elem| {
        const next = try stepped.next(reader.reader());
        try testing.expect(next != null and next.? == elem);
    }
    try testing.expect((try stepped.next(reader.reader())) == null);
}

/// optional type. represents when there may or may not be more data. potential data is
/// prefixed with a boolean. if boolean is true, there is data after
pub fn Optional(comptime UsedSpec: type, comptime T: type) type {
    return struct {
        pub const InnerType = UsedSpec.Spec(@typeInfo(T).Optional.child);
        pub const UserType = ?InnerType.UserType;
        pub fn write(self: UserType, writer: anytype) !void {
            try Bool.write(self != null, writer);
            if (self) |inner| {
                try InnerType.write(inner, writer);
            }
        }
        usingnamespace if (@hasDecl(InnerType, "readAlloc")) struct {
            pub const read = @compileError("Inner type may use allocation. use readAlloc");

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
        } else struct {
            pub fn read(reader: anytype) !UserType {
                if (try Bool.read(reader)) {
                    return try InnerType.read(reader);
                }
                return null;
            }
        };
        pub fn readRest(reader: anytype) !void {
            if (try Bool.read(reader)) {
                try noRead(InnerType, reader);
            }
        }
        pub fn size(self: UserType) usize {
            if (self) |inner| {
                return 1 + InnerType.size(inner);
            }
            return 1;
        }
    };
}

/// reads a utf8 string where the provided length is the number of codepoints (not number of bytes).
/// requires a length
pub const CodepointArray = struct {
    pub const UserType = []const u8;
    pub const IntType = usize;

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

    pub fn getInt(self: UserType) usize {
        // *should* be valid utf8 codepoints? any error should be found during read?
        return unicode.utf8CountCodepoints(self) catch unreachable;
    }

    pub fn write(self: UserType, writer: anytype) !void {
        try writer.writeAll(self);
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

    pub fn readRest(reader: anytype, len: usize) !UserType {
        var iter = Stepped.init(len);
        while (try iter.next(reader)) |_| {}
    }

    pub fn size(self: UserType) usize {
        return self.len;
    }
};

fn testSpec(comptime PacketType: type, alloc: Allocator, data: []const u8) !PacketType.UserType {
    var stream = std.io.fixedBufferStream(data);
    var result = if (@hasDecl(PacketType, "readAlloc")) try PacketType.readAlloc(alloc, stream.reader()) else try PacketType.read(stream.reader());
    errdefer if (@hasDecl(PacketType, "readAlloc")) PacketType.deinit(result, alloc);
    var buffer = std.ArrayList(u8).init(alloc);
    defer buffer.deinit();
    try PacketType.write(result, buffer.writer());
    try testing.expectEqualSlices(u8, data, buffer.items);
    try testing.expectEqual(u8, PacketType.size(result), buffer.items.len);
    return result;
}

test "codepoint string" {
    const words = "你好，我们没有时间。";
    var buf: [words.len]u8 = undefined;
    std.mem.copy(u8, &buf, words);
    var reader = std.io.fixedBufferStream(&buf);
    var result = try CodepointArray.readAlloc(testing.allocator, reader.reader(), 10);
    defer CodepointArray.deinit(result, testing.allocator);
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();
    try CodepointArray.write(result, buffer.writer());
    try testing.expectEqual(@as(usize, 10), CodepointArray.getInt(result));
    try testing.expectEqualStrings(words, result);
    try testing.expectEqual(@as(usize, 30), CodepointArray.size(result));
}
