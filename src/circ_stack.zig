const std = @import("std");

pub fn CircularStack(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        head: usize = 0,
        count: usize = 0,
        buf: [capacity]T = undefined,

        pub fn init() Self {
            return Self{};
        }

        pub fn reset(self: *Self) void {
            self.head = 0;
            self.count = 0;
        }

        pub fn push(self: *Self, v: T) ?T {
            const prev_elem = if (self.count == capacity) self.buf[self.head] else null;

            self.buf[self.head] = v;
            self.head = (self.head + 1) % capacity;
            if (self.count != capacity) self.count += 1;

            return prev_elem;
        }

        pub fn pop(self: *Self) ?T {
            if (self.count == 0) return null;

            self.head = if (self.head == 0) capacity - 1 else self.head - 1;
            const value = self.buf[self.head];
            self.count -= 1;
            return value;
        }
    };
}

const testing = std.testing;

test "CircularStack: push and pop basic operations" {
    var stack = CircularStack(u32, 5).init();

    _ = stack.push(1);
    _ = stack.push(2);
    _ = stack.push(3);

    try testing.expectEqual(@as(?u32, 3), stack.pop());
    try testing.expectEqual(@as(?u32, 2), stack.pop());
    try testing.expectEqual(@as(?u32, 1), stack.pop());
    try testing.expectEqual(@as(?u32, null), stack.pop());
}

test "CircularStack: wraparound behavior at capacity" {
    var stack = CircularStack(u32, 3).init();

    _ = stack.push(1);
    _ = stack.push(2);
    _ = stack.push(3);

    const evicted = stack.push(4);
    try testing.expectEqual(@as(?u32, 1), evicted);

    try testing.expectEqual(@as(?u32, 4), stack.pop());
    try testing.expectEqual(@as(?u32, 3), stack.pop());
    try testing.expectEqual(@as(?u32, 2), stack.pop());
}

test "CircularStack: reset clears all entries" {
    var stack = CircularStack(u32, 5).init();

    _ = stack.push(1);
    _ = stack.push(2);
    _ = stack.push(3);

    stack.reset();

    try testing.expectEqual(@as(?u32, null), stack.pop());
    try testing.expectEqual(@as(usize, 0), stack.count);
}
