const std = @import("std");
const vaxis = @import("vaxis");

pub fn List(comptime T: type) type {
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        items: std.ArrayList(T),
        selected: usize,

        pub fn init(alloc: std.mem.Allocator) Self {
            return Self{
                .alloc = alloc,
                .items = .empty,
                .selected = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.alloc);
        }

        pub fn append(self: *Self, item: T) !void {
            try self.items.append(self.alloc, item);
        }

        pub fn clear(self: *Self) void {
            self.items.clearAndFree(self.alloc);
            self.selected = 0;
        }

        pub fn fromArray(self: *Self, array: []const T) !void {
            for (array) |item| {
                try self.append(item);
            }
        }

        pub fn get(self: Self, index: usize) !T {
            if (index + 1 > self.len()) {
                return error.OutOfBounds;
            }

            return self.all()[index];
        }

        pub fn getSelected(self: *Self) !?T {
            if (self.len() > 0) {
                if (self.selected >= self.len()) {
                    self.selected = self.len() - 1;
                }

                return try self.get(self.selected);
            }

            return null;
        }

        pub fn all(self: Self) []T {
            return self.items.items;
        }

        pub fn len(self: Self) usize {
            return self.items.items.len;
        }

        pub fn next(self: *Self) void {
            if (self.selected + 1 < self.len()) {
                self.selected += 1;
            }
        }

        pub fn previous(self: *Self) void {
            if (self.selected > 0) {
                self.selected -= 1;
            }
        }

        pub fn selectLast(self: *Self) void {
            self.selected = self.len() - 1;
        }

        pub fn selectFirst(self: *Self) void {
            self.selected = 0;
        }
    };
}

const testing = std.testing;

test "List: navigation respects bounds" {
    var list = List(u32).init(testing.allocator);
    defer list.deinit();

    try list.append(1);
    try list.append(2);
    try list.append(3);

    try testing.expectEqual(@as(usize, 0), list.selected);

    list.next();
    try testing.expectEqual(@as(usize, 1), list.selected);

    list.next();
    list.next();
    // Try to go past end
    list.next();
    // Should stay at last
    try testing.expectEqual(@as(usize, 2), list.selected);

    list.previous();
    try testing.expectEqual(@as(usize, 1), list.selected);

    list.previous();
    // Try to go before start
    list.previous();
    // Should stay at first
    try testing.expectEqual(@as(usize, 0), list.selected);
}

test "List: getSelected handles empty list" {
    var list = List(u32).init(testing.allocator);
    defer list.deinit();

    const result = try list.getSelected();
    try testing.expect(result == null);
}

test "List: append and get operations" {
    var list = List(u32).init(testing.allocator);
    defer list.deinit();

    try list.append(42);
    try list.append(84);

    try testing.expectEqual(@as(usize, 2), list.len());
    try testing.expectEqual(@as(u32, 42), try list.get(0));
    try testing.expectEqual(@as(u32, 84), try list.get(1));
}

test "List: selectFirst and selectLast" {
    var list = List(u32).init(testing.allocator);
    defer list.deinit();

    try list.append(1);
    try list.append(2);
    try list.append(3);

    list.selectLast();
    try testing.expectEqual(@as(usize, 2), list.selected);

    list.selectFirst();
    try testing.expectEqual(@as(usize, 0), list.selected);
}
