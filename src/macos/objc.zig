/// ObjC runtime helpers for calling macOS frameworks from Zig.
/// Pattern borrowed from Ghostty (ghostty-org/ghostty).
/// Reference: Code-Hex/vz (Go) for Virtualization.framework API mapping.

const std = @import("std");

// ── Types ────────────────────────────────────────────────────────────

pub const Class = *opaque {};
pub const SEL = *opaque {};
pub const id = *opaque {};
pub const BOOL = i8;
pub const NSUInteger = usize;
pub const NSInteger = isize;

// CoreGraphics geometry types (NSRect/NSPoint/NSSize are typedef'd to these on 64-bit)
pub const CGFloat = f64;

pub const NSPoint = extern struct {
    x: CGFloat = 0,
    y: CGFloat = 0,
};

pub const NSSize = extern struct {
    width: CGFloat = 0,
    height: CGFloat = 0,
};

pub const NSRect = extern struct {
    origin: NSPoint = .{},
    size: NSSize = .{},
};

pub const YES: BOOL = 1;
pub const NO: BOOL = 0;

// ── ObjC Runtime Externs ─────────────────────────────────────────────

extern "c" fn objc_getClass(name: [*:0]const u8) ?Class;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_msgSend() void;

// For methods returning large structs (not needed on aarch64, but declare for completeness)
extern "c" fn objc_msgSend_stret() void;

// ── Core Helpers ─────────────────────────────────────────────────────

pub fn getClass(name: [*:0]const u8) ?Class {
    return objc_getClass(name);
}

pub fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

/// Comptime-typed objc_msgSend wrapper.
/// Builds the correct function pointer type from the return type and argument tuple,
/// then calls through objc_msgSend with proper ABI.
pub fn msgSend(comptime R: type, target: anytype, selector: SEL, args: anytype) R {
    const TargetType = @TypeOf(target);
    const target_ptr: *const anyopaque = switch (@typeInfo(TargetType)) {
        .pointer => @ptrCast(target),
        .optional => if (target) |t| @as(*const anyopaque, @ptrCast(t)) else @panic("msgSend on null target"),
        else => @compileError("msgSend target must be a pointer type"),
    };

    const FnType = comptime buildMsgSendFn(R, TargetType, @TypeOf(args));
    const func: *const FnType = @ptrCast(&objc_msgSend);
    return @call(.auto, func, .{target_ptr, selector} ++ args);
}

fn buildMsgSendFn(comptime R: type, comptime Target: type, comptime ArgsTuple: type) type {
    _ = Target;
    const args_info = @typeInfo(ArgsTuple).@"struct";
    const total_params = 2 + args_info.fields.len;

    var params: [total_params]std.builtin.Type.Fn.Param = undefined;

    // self (target)
    params[0] = .{
        .is_generic = false,
        .is_noalias = false,
        .type = *const anyopaque,
    };
    // _cmd (selector)
    params[1] = .{
        .is_generic = false,
        .is_noalias = false,
        .type = SEL,
    };
    // remaining args
    for (args_info.fields, 0..) |field, i| {
        params[2 + i] = .{
            .is_generic = false,
            .is_noalias = false,
            .type = field.type,
        };
    }

    return @Type(.{ .@"fn" = .{
        .calling_convention = .c,
        .is_var_args = false,
        .is_generic = false,
        .params = &params,
        .return_type = R,
    } });
}

// ── Convenience ──────────────────────────────────────────────────────

/// Allocate a new instance: [Class alloc]
pub fn alloc(class: Class) id {
    return msgSend(id, class, sel("alloc"), .{});
}

/// Send -init to an allocated object
pub fn init(obj: id) id {
    return msgSend(id, obj, sel("init"), .{});
}

/// Send -autorelease
pub fn autorelease(obj: id) id {
    return msgSend(id, obj, sel("autorelease"), .{});
}

/// Send -release
pub fn release(obj: id) void {
    msgSend(void, obj, sel("release"), .{});
}

/// Send -retain
pub fn retain(obj: id) id {
    return msgSend(id, obj, sel("retain"), .{});
}

// ── NSString ─────────────────────────────────────────────────────────

/// Create an NSString from a Zig null-terminated string.
/// +[NSString stringWithUTF8String:]
pub fn nsString(str: [*:0]const u8) id {
    const NSString = getClass("NSString") orelse @panic("NSString class not found");
    return msgSend(id, NSString, sel("stringWithUTF8String:"), .{str});
}

/// Extract a C string from an NSString.
/// -[NSString UTF8String]
/// The returned pointer is valid for the lifetime of the NSString (or its autorelease pool).
pub fn fromNSString(ns_str: id) [*:0]const u8 {
    return msgSend([*:0]const u8, ns_str, sel("UTF8String"), .{});
}

/// Create an NSString from a Zig slice (not necessarily null-terminated).
/// Uses -[NSString initWithBytes:length:encoding:]
pub fn nsStringFromSlice(str: []const u8) id {
    const NSString = getClass("NSString") orelse @panic("NSString class not found");
    const obj = alloc(NSString);
    const NSUTF8StringEncoding: NSUInteger = 4;
    return msgSend(id, obj, sel("initWithBytes:length:encoding:"), .{
        str.ptr,
        @as(NSUInteger, str.len),
        NSUTF8StringEncoding,
    });
}

// ── NSURL ────────────────────────────────────────────────────────────

/// Create an NSURL from a file path string.
/// +[NSURL fileURLWithPath:]
pub fn nsURL(path: [*:0]const u8) id {
    const NSURL = getClass("NSURL") orelse @panic("NSURL class not found");
    const path_str = nsString(path);
    return msgSend(id, NSURL, sel("fileURLWithPath:"), .{path_str});
}

/// Create an NSURL from a URL string.
/// +[NSURL URLWithString:]
pub fn nsURLFromString(url_string: [*:0]const u8) ?id {
    const NSURL = getClass("NSURL") orelse @panic("NSURL class not found");
    const str = nsString(url_string);
    const result = msgSend(?id, NSURL, sel("URLWithString:"), .{str});
    return result;
}

// ── NSArray / NSMutableArray ─────────────────────────────────────────

/// Create an empty NSMutableArray.
pub fn nsMutableArray() id {
    const NSMutableArray = getClass("NSMutableArray") orelse @panic("NSMutableArray class not found");
    return init(alloc(NSMutableArray));
}

/// -[NSMutableArray addObject:]
pub fn arrayAddObject(array: id, obj: id) void {
    msgSend(void, array, sel("addObject:"), .{obj});
}

/// -[NSArray count]
pub fn arrayCount(array: id) NSUInteger {
    return msgSend(NSUInteger, array, sel("count"), .{});
}

/// -[NSArray objectAtIndex:]
pub fn arrayObjectAtIndex(array: id, index: NSUInteger) id {
    return msgSend(id, array, sel("objectAtIndex:"), .{index});
}

// ── NSDictionary ─────────────────────────────────────────────────────

/// Create an empty NSMutableDictionary.
pub fn nsMutableDictionary() id {
    const NSMutableDictionary = getClass("NSMutableDictionary") orelse @panic("NSMutableDictionary class not found");
    return init(alloc(NSMutableDictionary));
}

/// -[NSMutableDictionary setObject:forKey:]
pub fn dictSetObject(dict: id, obj: id, key: id) void {
    msgSend(void, dict, sel("setObject:forKey:"), .{ obj, key });
}

// ── NSNumber ─────────────────────────────────────────────────────────

/// +[NSNumber numberWithBool:]
pub fn nsNumberWithBool(val: bool) id {
    const NSNumber = getClass("NSNumber") orelse @panic("NSNumber class not found");
    return msgSend(id, NSNumber, sel("numberWithBool:"), .{@as(BOOL, if (val) YES else NO)});
}

/// +[NSNumber numberWithUnsignedInteger:]
pub fn nsNumberWithUInt(val: NSUInteger) id {
    const NSNumber = getClass("NSNumber") orelse @panic("NSNumber class not found");
    return msgSend(id, NSNumber, sel("numberWithUnsignedInteger:"), .{val});
}

// ── NSFileHandle ─────────────────────────────────────────────────────

/// [[NSFileHandle alloc] initWithFileDescriptor:]
pub fn fileHandleWithDescriptor(fd: i32) id {
    const NSFileHandle = getClass("NSFileHandle") orelse @panic("NSFileHandle class not found");
    const obj = alloc(NSFileHandle);
    return msgSend(id, obj, sel("initWithFileDescriptor:"), .{fd});
}

// ── NSError ──────────────────────────────────────────────────────────

/// -[NSError localizedDescription] -> NSString
pub fn errorDescription(err: id) [*:0]const u8 {
    const desc = msgSend(id, err, sel("localizedDescription"), .{});
    return fromNSString(desc);
}

// ── NSData ──────────────────────────────────────────────────────────

/// -[NSData bytes]
pub fn dataBytes(data: id) [*]const u8 {
    return msgSend([*]const u8, data, sel("bytes"), .{});
}

/// -[NSData length]
pub fn dataLength(data: id) NSUInteger {
    return msgSend(NSUInteger, data, sel("length"), .{});
}

/// Get NSData contents as a Zig slice.
pub fn dataSlice(data: id) []const u8 {
    const len = dataLength(data);
    if (len == 0) return &.{};
    return dataBytes(data)[0..len];
}

/// +[NSData dataWithBytes:length:]
pub fn nsDataFromSlice(bytes: []const u8) id {
    const NSData = getClass("NSData") orelse @panic("NSData class not found");
    return msgSend(id, NSData, sel("dataWithBytes:length:"), .{
        bytes.ptr,
        @as(NSUInteger, bytes.len),
    });
}

// ── NSFileHandle fd extraction ──────────────────────────────────────

/// -[NSFileHandle fileDescriptor] -> int
pub fn fileDescriptor(fh: id) i32 {
    return msgSend(i32, fh, sel("fileDescriptor"), .{});
}

// ── Runtime class creation ──────────────────────────────────────────
// For creating ObjC delegate classes at runtime (needed for VZVirtioSocketListener).

extern "c" fn objc_allocateClassPair(superclass: ?Class, name: [*:0]const u8, extra_bytes: usize) ?Class;
extern "c" fn objc_registerClassPair(cls: Class) void;
extern "c" fn class_addMethod(cls: Class, name: SEL, imp: *const anyopaque, types: [*:0]const u8) bool;

/// Register a new ObjC class at runtime, subclassing NSObject.
/// Returns null if the class name is already taken.
pub fn createClass(name: [*:0]const u8) ?Class {
    const NSObject = getClass("NSObject") orelse @panic("NSObject class not found");
    return objc_allocateClassPair(NSObject, name, 0);
}

/// Add a method to a class being constructed.
/// `types` is the ObjC type encoding string (e.g. "v@:@@" for void method with 2 object args).
/// `imp` is the C-callable function pointer implementing the method.
pub fn addMethod(cls: Class, selector: SEL, imp: *const anyopaque, types: [*:0]const u8) bool {
    return class_addMethod(cls, selector, imp, types);
}

/// Finalize and register a class created with createClass.
pub fn registerClass(cls: Class) void {
    objc_registerClassPair(cls);
}

// ── ObjC Block ABI ──────────────────────────────────────────────────
// Layout for constructing ObjC blocks from Zig.
// On aarch64, blocks are structs with a specific layout that the runtime
// knows how to call. We need this for completion handlers.

extern "c" var _NSConcreteStackBlock: anyopaque;

pub const BlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};

/// Construct a stack block struct type for a given invoke function type.
/// Usage: const MyBlock = Block(fn (*anyopaque, ?id) callconv(.c) void);
pub fn Block(comptime InvokeFn: type) type {
    return extern struct {
        isa: *anyopaque = &_NSConcreteStackBlock,
        flags: c_int = 0,
        reserved: c_int = 0,
        invoke: *const InvokeFn,
        descriptor: *const BlockDescriptor,
    };
}

/// Create a block descriptor with the correct size for a given block type.
pub fn blockDescriptor(comptime BlockType: type) BlockDescriptor {
    return .{
        .size = @sizeOf(BlockType),
    };
}

// ── Tests ────────────────────────────────────────────────────────────

test "NSString round-trip" {
    const input = "hello from zig";
    const ns = nsString(input);
    const output = fromNSString(ns);
    const output_slice = std.mem.span(output);
    try std.testing.expectEqualStrings(input, output_slice);
}

test "NSString from slice" {
    const input: []const u8 = "slice test";
    const ns = nsStringFromSlice(input);
    const output = fromNSString(ns);
    const output_slice = std.mem.span(output);
    try std.testing.expectEqualStrings(input, output_slice);
}

test "NSMutableArray basic operations" {
    const arr = nsMutableArray();
    try std.testing.expectEqual(@as(NSUInteger, 0), arrayCount(arr));

    arrayAddObject(arr, nsString("first"));
    arrayAddObject(arr, nsString("second"));
    try std.testing.expectEqual(@as(NSUInteger, 2), arrayCount(arr));

    const first = arrayObjectAtIndex(arr, 0);
    const first_str = std.mem.span(fromNSString(first));
    try std.testing.expectEqualStrings("first", first_str);
}

test "getClass returns null for nonexistent class" {
    const result = getClass("ZZZNonexistentClass12345");
    try std.testing.expect(result == null);
}

test "getClass returns non-null for NSString" {
    const result = getClass("NSString");
    try std.testing.expect(result != null);
}
