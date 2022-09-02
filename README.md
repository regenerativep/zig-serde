# zig-serde

Serialization and deserialization library in Zig.

I made this to make it easy to specify a format using Zig types and just be given the functions necessary to serialize and deserialize the data specified by the format.

warning: following parts of readme might not be up to date

## Usage

Specify a format. This is in the form of a Zig type.

```zig
const Gamemode = enum(u8) {
    survival = 0,
    creative = 1,
    spectator = 2,
};
const MySpecification = serde.Struct(serde.DefaultSpec, struct {
    name: serde.PrefixedArray(serde.DefaultSpec, u8, u8),
    id: i32,
    gamemode: Gamemode,
});
```

Here we can see some things. `serde.DefaultSpec` is a type containing a function called `Spec` which will take in any Zig type and return the corresponding serde type. This is used to figure out how to convert some types like `i32` and `Gamemode`. If `Spec` detects that the provided type is already a serde type, then the serde type will just be returned. `serde.Struct` specifically takes in only Zig structs, and is also used by `DefaultSpec.Spec` when it detects a struct. As such, `serde.Struct` in the above code could be replaced by `serde.DefaultSpec.Spec`. One could write their own version of `DefaultSpec` if necessary.

Next, we see that we can specify types `i32`, `Gamemode`, and a special type `serde.PrefixedArray`. `DefaultSpec` serializes numbers as big endian (but you can also specify otherwise through directly using `serde.Num`. `serde.PrefixedArray` doesn't actually store any data on its own, it itself is just a type with several functions and its own `UserType`. To use it, we are just passing in first the type of the length, and then the type of the elements.

`MySpecification` is now a type with several functions and at least one declaration. To the Zig compiler, the resulting type looks something like this:

```zig
const MySpecification = struct {
    pub const UserType = struct {
        name: []const u8,
        id: i32,
        gamemode: Gamemode,
    };
    //...
    
    pub const read = @compileError("Requires allocation");
    pub fn readAlloc(alloc: Allocator, reader: anytype) !UserType {
        //...
    }
    pub fn deinit(self: UserType, alloc: Allocator) void {
        //...
    }
    pub fn write(self: UserType, writer: anytype) !void {
        //...
    }
    pub fn size(self: UserType) usize {
        //...
    }
    //...
};
```

`UserType` is a type that contains the actual data that comes from a deserialization or the data you want to serialize. This is derived from the specification provided.

`read` performs deserialization with no allocation. `serde.Struct` discovered one of the fields requires allocation, so the entire type then requires allocation and you can't use `read`.

`readAlloc` deserializes with possible allocation. This returns a `UserType`. `deinit` is made to deinitialize a deserialized `UserType`.

`write` serializes provided a `UserType`. `size` returns the total number of bytes `write` would write.

```zig
const data = MySpecification.UserType{
    .name = "potato",
    .id = 20,
    .gamemode = .survival,
};

var written = std.ArrayList(u8).init(testing.allocator);
defer written.deinit();
try MySpecification.write(data, written.writer());

const expected = [_]u8{ 6, 'p', 'o', 't', 'a', 't', 'o', 0, 0, 0, 20, 0 };
try testing.expectEqualSlices(u8, &expected, written.items);
try testing.expectEqual(MySpecification.size(data), expected.len);

var stream = std.io.fixedBufferStream(&expected);
var read_data = try MySpecification.readAlloc(testing.allocator, stream.reader());
defer MySpecification.deinit(read_data, testing.allocator);

try testing.expectEqualSlices(data.name, read_data.name);
try testing.expectEqual(data.id, read_data.id);
try testing.expectEqual(data.gamemode, read_data.gamemode);
```
