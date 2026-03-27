/// Security.framework bindings for Keychain access.
/// These are plain C APIs — no ObjC runtime needed for the Security calls,
/// but we use Foundation types (NSDictionary) for query construction since
/// CFDictionary is toll-free bridged with NSDictionary.

const std = @import("std");
const objc = @import("objc");

// ── Security.framework C API ────────────────────────────────────────

extern "c" fn SecItemCopyMatching(query: objc.id, result: *?objc.id) i32;
extern "c" fn SecItemAdd(attributes: objc.id, result: ?*?objc.id) i32;
extern "c" fn SecItemUpdate(query: objc.id, attrs_to_update: objc.id) i32;
extern "c" fn SecItemDelete(query: objc.id) i32;

// ── Security.framework constants (CFString, toll-free bridged) ──────

extern "c" var kSecClass: objc.id;
extern "c" var kSecClassGenericPassword: objc.id;
extern "c" var kSecAttrService: objc.id;
extern "c" var kSecAttrAccount: objc.id;
extern "c" var kSecReturnData: objc.id;
extern "c" var kSecValueData: objc.id;
extern "c" var kSecMatchLimit: objc.id;
extern "c" var kSecMatchLimitOne: objc.id;

// CoreFoundation boolean
extern "c" var kCFBooleanTrue: objc.id;

// ── Status codes ────────────────────────────────────────────────────

pub const errSecSuccess: i32 = 0;
pub const errSecItemNotFound: i32 = -25300;
pub const errSecDuplicateItem: i32 = -25299;

// ── Public API ──────────────────────────────────────────────────────

pub const KeychainError = error{
    NotFound,
    DuplicateItem,
    SecurityError,
};

/// Look up a generic password in the Keychain.
/// Returns the password bytes, or null if not found.
/// Caller must free the returned slice with `allocator.free()`.
pub fn getPassword(allocator: std.mem.Allocator, service: []const u8, account: []const u8) KeychainError!?[]u8 {
    const query = objc.nsMutableDictionary();
    objc.dictSetObject(query, kSecClassGenericPassword, kSecClass);
    objc.dictSetObject(query, objc.nsStringFromSlice(service), kSecAttrService);
    objc.dictSetObject(query, objc.nsStringFromSlice(account), kSecAttrAccount);
    objc.dictSetObject(query, kCFBooleanTrue, kSecReturnData);
    objc.dictSetObject(query, kSecMatchLimitOne, kSecMatchLimit);

    var result: ?objc.id = null;
    const status = SecItemCopyMatching(query, &result);

    if (status == errSecItemNotFound) return null;
    if (status != errSecSuccess) return error.SecurityError;

    // result is a CFData (toll-free bridged with NSData)
    if (result) |data| {
        const slice = objc.dataSlice(data);
        const owned = allocator.alloc(u8, slice.len) catch return error.SecurityError;
        @memcpy(owned, slice);
        return owned;
    }
    return null;
}

/// Store a generic password in the Keychain.
/// If the item already exists, it will be updated.
pub fn setPassword(service: []const u8, account: []const u8, password: []const u8) KeychainError!void {
    const ns_service = objc.nsStringFromSlice(service);
    const ns_account = objc.nsStringFromSlice(account);
    const ns_password = objc.nsDataFromSlice(password);

    // Try to update first
    const query = objc.nsMutableDictionary();
    objc.dictSetObject(query, kSecClassGenericPassword, kSecClass);
    objc.dictSetObject(query, ns_service, kSecAttrService);
    objc.dictSetObject(query, ns_account, kSecAttrAccount);

    const update_attrs = objc.nsMutableDictionary();
    objc.dictSetObject(update_attrs, ns_password, kSecValueData);

    const update_status = SecItemUpdate(query, update_attrs);
    if (update_status == errSecSuccess) return;

    if (update_status == errSecItemNotFound) {
        // Item doesn't exist yet, add it
        const add_attrs = objc.nsMutableDictionary();
        objc.dictSetObject(add_attrs, kSecClassGenericPassword, kSecClass);
        objc.dictSetObject(add_attrs, ns_service, kSecAttrService);
        objc.dictSetObject(add_attrs, ns_account, kSecAttrAccount);
        objc.dictSetObject(add_attrs, ns_password, kSecValueData);

        const add_status = SecItemAdd(add_attrs, null);
        if (add_status != errSecSuccess) return error.SecurityError;
        return;
    }

    return error.SecurityError;
}

/// Delete a generic password from the Keychain.
/// Returns NotFound if the item doesn't exist.
pub fn deletePassword(service: []const u8, account: []const u8) KeychainError!void {
    const query = objc.nsMutableDictionary();
    objc.dictSetObject(query, kSecClassGenericPassword, kSecClass);
    objc.dictSetObject(query, objc.nsStringFromSlice(service), kSecAttrService);
    objc.dictSetObject(query, objc.nsStringFromSlice(account), kSecAttrAccount);

    const status = SecItemDelete(query);
    if (status == errSecItemNotFound) return error.NotFound;
    if (status != errSecSuccess) return error.SecurityError;
}

// ── Tests ────────────────────────────────────────────────────────────

test "keychain set, get, delete round-trip" {
    const allocator = std.testing.allocator;
    const service = "lcl-bridge-test";
    const account = "test-user";
    const password = "test-password-42";

    // Clean up any leftover from previous test run
    deletePassword(service, account) catch {};

    // Set
    try setPassword(service, account, password);

    // Get
    const result = try getPassword(allocator, service, account);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(password, result.?);
    allocator.free(result.?);

    // Update
    const new_password = "updated-password-99";
    try setPassword(service, account, new_password);
    const result2 = try getPassword(allocator, service, account);
    try std.testing.expect(result2 != null);
    try std.testing.expectEqualStrings(new_password, result2.?);
    allocator.free(result2.?);

    // Delete
    try deletePassword(service, account);

    // Verify deleted
    const result3 = try getPassword(allocator, service, account);
    try std.testing.expect(result3 == null);
}

test "keychain get nonexistent returns null" {
    const allocator = std.testing.allocator;
    const result = try getPassword(allocator, "lcl-nonexistent-service-xyz", "nobody");
    try std.testing.expect(result == null);
}

test "keychain delete nonexistent returns NotFound" {
    const result = deletePassword("lcl-nonexistent-service-xyz", "nobody");
    try std.testing.expectError(KeychainError.NotFound, result);
}
