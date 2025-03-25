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
                .items = std.ArrayList(T).init(alloc),
                .selected = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit();
        }

        pub fn append(self: *Self, item: T) !void {
            try self.items.append(item);
        }

        pub fn clear(self: *Self) void {
            self.items.clearAndFree();
            self.selected = 0;
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
