const std = @import("std");
const debug = std.debug;
const assert = debug.assert;
const testing = std.testing;
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;

/// A double-ended queue implemented with a growable ring buffer
/// For consistently fast access even when wrapping around the slice boundary,
/// it has been implemented to always have a power of two capacity
/// If memory is a concern and capacity does not need to be dynamic, use `RingBuffer`
pub fn ArrayDeque(comptime T: type) type {
    return ArrayDequeAligned(T, null);
}

fn wrap_index(logical_index: usize, capacity: usize) usize {
    assert(logical_index == 0 and capacity == 0 
        or logical_index < capacity
        or (logical_index - capacity) < capacity
    );
    return if (logical_index >= capacity) logical_index - capacity else logical_index;
}

pub fn ArrayDequeAligned(comptime T: type, comptime alignment: ?u29) type {
    if (alignment) |a| {
        if (a == @alignOf(T)) {
            return ArrayDequeAligned(T, null);
        }
    }
    return struct {
        const Self = @This();
        /// Contents of this deque. This field is NOT intended to be accessed
        /// directly.
        unmanaged: Unmanaged,
        allocator: Allocator,

        const Unmanaged = ArrayDequeUnmanaged(T);

        const Slice = if (alignment) |a| ([]align(a) T) else []T;

        /// Deinitialize with `deinit`
        pub fn init(allocator: Allocator) Self {
            return Self{
                .unmanaged = .{},
                .allocator = allocator,
            };
        }

        /// Initialize with capacity to hold `num` elements.
        /// The resulting capacity will equal the smallest power of two greater than or equal to `num`.
        /// Deinitialize with `deinit`
        pub fn initCapacity(allocator: Allocator, num: usize) Allocator.Error!Self {
            var self = Self.init(allocator);
            try self.ensureTotalCapacity(num);
            return self;
        }

        /// Release all allocated memory.
        pub fn deinit(self: *Self) void {
            self.unmanaged.deinit(self.allocator);
        }

        pub fn len(self: *Self) usize {
            return self.unmanaged.len;
        }

        // /// ArrayListUnmanaged takes ownership of the passed in slice. The slice must have been
        // /// allocated with `allocator`.
        // /// Deinitialize with `deinit` or use `toOwnedSlice`.
        // pub fn fromOwnedSlice(slice: Slice) Self {
        //     return .{
        //         .items = slice,
        //         .len = 
        //     };
        // }

        // pub fn fromOwnedSliceAssumeCapacity(allocator: Allocator, slice: Slice) Self {
        //     assert(allocator.resize(slice, math.ceilPowerOfTwo(usize, slice.len) catch unreachable));
        // }

        fn is_full(self: *Self) bool {
            return self.unmanaged.isFull();
        }

        /// The caller owns the returned memory. Empties this ArrayDeque.
        /// Its capacity is cleared, making deinit() safe but unnecessary to call.
        /// The returned memory may not be contiguous, use `makeContiguous` first
        /// or use `asSlices` to return both non-contiguous slices
        pub fn toOwnedSlice(self: *Self) Allocator.Error!Slice {
            return self.unmanaged.toOwnedSlice(self.allocator);
        }

        /// Initializes an ArrayDequeUnmanaged with the `data` and `len` fields
        /// of this ArrayDeque. Empties this ArrayDeque.
        pub fn moveToUnmanaged(self: *Self) ArrayDequeAlignedUnmanaged(T, alignment) {
            const allocator = self.allocator;
            const result = self.unmanaged;
            self.* = init(allocator);
            return result;
        }

        /// The size of the underlying buffer
        pub fn capacity(self: *Self) usize {
            return self.unmanaged.capacity();
        }

        /// Returns the index just after the last occupied element
        fn tail(self: *Self) usize {
            return self.unmanaged.tail();
        }

        /// Empties the deque without deallocating the backing slice.
        /// Invalidates all element pointers.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.unmanaged.clearRetainingCapacity();
        }

        /// Extend the deque by 1 element from the back. Allocates more memory as necessary.
        /// Invalidates pointers if additional memory is needed.
        pub fn append(self: *Self, item: T) Allocator.Error!void {
            return self.unmanaged.append(self.allocator, item);
        }

        /// Extend the deque by 1 element from the front. Allocates more memory as necessary.
        /// Invalidates pointers if additional memory is needed.
        pub fn prepend(self: *Self, item: T) Allocator.Error!void {
            return self.unmanaged.prepend(self.allocator, item);
        }


        pub fn addOne(self: *Self) Allocator.Error!*T {
            return self.unmanaged.addOne(self.allocator);
        }

        /// Increase length by 1, returning pointer to the new item.
        /// Asserts that there is already space for the new item without allocating more.
        /// The returned pointer becomes invalid when the list is resized.
        /// **Does not** invalidate element pointers.
        pub fn addOneAssumeCapacity(self: *Self) *T {
            return self.unmanaged.addOneAssumeCapacity();
        }

        pub fn addManyAsArrayAssumeCapacity(self: *Self, comptime n: usize) *[n]T {
            return self.unmanaged.addManyAsArrayAssumeCapacity(n);
        }

        /// Append the slice of items to the deque.
        /// Allocates more memory as necessary.
        /// Invalidates pointers if additional memory is needed.
        pub fn appendSlice(self: *Self, items: []const T) Allocator.Error!void {
            try self.ensureUnusedCapacity(items.len);
            const slices = self.unusedCapacitySlices();
            assert(slices[0].len + slices[1].len >= items.len);
            self.appendSliceAssumeCapacity(items);
        }

        /// Append the slice of items to the deque, asserting the capacity is already
        /// enough to store the new items. **Does not** invalidate pointers.
        pub fn appendSliceAssumeCapacity(self: *Self, items: []const T) void {
            return self.unmanaged.appendSliceAssumeCapacity(items);
        }

        /// Creates a copy of this ArrayDeque, using the same allocator.
        /// The items will be laid out identically in memory to the current backing slice.
        /// To create a copy with contiguous data, use `cloneContiguous`.
        pub fn clone(self: Self) Allocator.Error!Self {
            return self.unmanaged.clone(self.allocator);
        }

        /// Creates a copy of this ArrayDeque, using the same allocator.
        /// The items will be laid out contiguously from the start of the new backing slice.
        /// To create an exact copy, use `clone`.
        pub fn cloneContiguous(self: Self) Allocator.Error!Self {
            var cloned = try Self.initCapacity(self.allocator, self.capacity());
            const slice1, const slice2 = self.asSlices();
            cloned.appendSliceAssumeCapacity(slice1);
            cloned.appendSliceAssumeCapacity(slice2);
            return cloned;
        }

        /// Returns the element at `index` with respect to the first element
        /// and the capacity of the ArrayDeque.
        /// Asserts that the index is in-bounds, use `getOrNull` if an optional type is desired
        pub fn get(self: *Self, i: usize) *T {
            return self.unmanaged.get(i);
        }

        /// Returns the element at `index` with respect to the first element
        /// and the capacity of the ArrayDeque.
        /// If `index` is out of bounds, returns `null`.
        pub fn getOrNull(self: *Self, i: usize) ?*T {
            return self.unmanaged.getOrNull(i);
        }

        /// Returns a pair of slices which contain, in order, the contents of the ArrayDeque
        /// if `makeContiguous` was previously called, all elements will be in the first slice
        /// and the second slice will be empty.
        pub fn asSlices(self: *Self) [2]Slice {
            return if (self.isContiguous())
                [2]Slice{self.items[self.head..self.head + self.len], &.{}}
            else 
                [2]Slice{self.items[self.head..], self.items[0..self.end()]};
        }

        /// Returns whether the deque wraps around the end of the backing slice.
        fn isContiguous(self: *Self) bool {
            return self.head <= self.capacity() - self.len;
        }

        /// 
        pub fn ensureUnusedCapacity(self: *Self, additional_count: usize) Allocator.Error!void {
            try self.ensureTotalCapacity(self.len + additional_count);
            assert(self.capacity() >= self.len + additional_count);
        }

        /// Increases the deque's length to match the full capacity that is already allocated.
        /// The new elements have `undefined` values. **Does not** invalidate pointers.
        pub fn expandToCapacity(self: *Self) void {
            self.len = self.capacity();
        }

        /// Rearranges the internal storage of the ArrayDeque so it is one contiguous slice, which is then returned.
        /// This does not allocate and does not return an owned Slice.
        /// The slice returned will start at `&self.buf[head]` and have a length of `self.len`
        pub fn asContiguousSlice(self: *Self) Slice {
            return self.unmanaged.asContiguousSlice();
        }

        /// Makes the deque fully contiguous and ensures that it starts
        /// at slot 0 of the backing slice.
        /// The slice returned is the length of the deque, not its capacity.
        pub fn asFullyContiguousSlice(self: *Self) Slice {
            return self.unmanaged.asFullyContiguousSlice();
        }

        /// Returns a slice of all the unused capacity from the tail 
        /// to the head or the end of the buffer, whichever comes first.
        /// In other words, if the deque is contiguous but `head`
        /// is not zero, the buffer from 0..head will not be part of,
        pub fn unusedCapacitySlice(self: Self) [2]Slice {
            return self.unmanaged.unusedCapacitySlice();
        }

        /// Returns slices containing the unused capacity of the deque.
        /// The first slice will always contain the slice 
        /// starting after the end of the deque.
        /// The second slice will contain the unused slice starting at index 0.
        /// If the slice is not contiguous or the head is at 0,
        /// the second slice will be empty
        pub fn unusedCapacitySlices(self: *Self) [2]Slice {
            return self.unmanaged.unusedCapacitySlices();
        }

        /// Remove and return the first element from the deque.
        /// Asserts the deque has at least one item.
        /// Invalidates pointers to first element.
        pub fn popFront(self: *Self) T {
            return self.unmanaged.popFront();
        }

        /// Remove and return the first element from the deque.
        /// If the deque is empty, returns `null`.
        /// Invalidates pointers to first element.
        pub fn popFrontOrNull(self: *Self) ?T {
            return self.unmanaged.popBackOrNull();
        }

        /// Remove and return the last element from the deque.
        /// Asserts the deque has at least one item.
        /// Invalidates pointers to last element.
        pub fn popBack(self: *Self) T {
            return self.unmanaged.popBack();
        }

        /// Remove and return the last element from the deque.
        /// If the deque is empty, returns `null`.
        /// Invalidates pointers to last element.
        pub fn popBackOrNull(self: *Self) ?T {
            return self.unmanaged.popBackOrNull();
        }

        /// Removes the element at the specified index and returns it.
        /// The empty slot is filled from the end of the deque
        /// Invalidates pointers to last element.
        /// This operation is O(1).
        pub fn swapRemove(self: *Self, i: usize) T {
            if (i == 0) return self.popFront();
            if (i == self.len - 1) return self.popBack();
        }

        fn resize(self: *Self) bool {
            return self.allocator.resize(self.items, @max(8, self.items.len *% 2));
        }

        fn grow(self: *Self) Allocator.Error!void {
            if (self.resize()) return;
            try self.ensureTotalCapacity(@max(8, self.items.len *% 2));
        }

        /// Modify the array so that it can hold `new_capacity` items.
        /// If an additional allocation is required, the backing buffer size
        /// will be doubled, 
        pub fn ensureTotalCapacity(self: *Self, new_capacity: usize) Allocator.Error!void {
            return self.unmanaged.ensureTotalCapacity(self.allocator, new_capacity);
        }

        fn copy(self: *Self, source: usize, dest: usize, n: usize) void {
            assert(dest + n <= self.capacity());
            assert(source + n <= self.capacity());
            const func = if (dest > source) mem.copyBackwards else mem.copyForwards;
            func(self.items[dest..dest + n], self.items[source..source + n]);
        }

        pub const Iterator = Unmanaged.Iterator;

        pub fn iterator(self: *Self) Iterator {
            self.unmanaged.iterator();
        }
    };
}

pub fn ArrayDequeUnmanaged(comptime T: type) type {
    return ArrayDequeAlignedUnmanaged(T, null);
}

pub fn ArrayDequeAlignedUnmanaged(comptime T: type, comptime alignment: ?u29) type {
    if (alignment) |a| {
        if (a == @alignOf(T)) {
            return ArrayDequeAlignedUnmanaged(T, null);
        }
    }
    return struct {
       const Self = @This();
        /// Contents of this deque. This field is NOT intended to be accessed
        /// directly.
        items: Slice = &[_]T{},
        head: usize = 0,
        /// Current number of T values stored in this deque
        len: usize = 0,

        const Slice = if (alignment) |a| ([]align(a) T) else []T;

        /// Initialize with capacity to hold `num` elements.
        /// The resulting capacity will equal the smallest power of two greater than or equal to `num`.
        /// Deinitialize with `deinit`
        pub fn initCapacity(allocator: Allocator, num: usize) Allocator.Error!Self {
            var self = Self{
                .head = 0,
                .len = 0,
            };
            try self.ensureTotalCapacity(allocator, num);
            return self;
        }

        /// Initialize with externally-managed memory. The buffer determines the
        /// capacity, and the length is set to zero.
        /// When initialized this way, all functions that accept an Allocator
        /// argument cause illegal behavior.
        pub fn initBuffer(buffer: Slice) Self {
            return .{
                .items = buffer,
                .len = 0,
            };
        }

        /// Release all allocated memory.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.items);
            self.* = undefined;
        }

        /// Convert this deque into an analogous memory-managed one.
        /// The returned deque has ownership of the underlying memory.
        pub fn toManaged(self: *Self, allocator: Allocator) ArrayDequeAligned(T, alignment) {
            return .{
                .unmanaged = self.*,
                .allocator = allocator,
            };
        }

        pub fn fromOwnedSlice(allocator: Allocator, slice: Slice) Self {
            //assert(slice.len < @as(usize, math.isPowerOfTwo(int: anytype) .minInt(isize)));
            if (!allocator.resize(slice, math.ceilPowerOfTwo(usize, slice.len) catch unreachable)) {

            }
        }

        pub fn fromOwnedSliceAssumeCapacity(allocator: Allocator, slice: Slice) Self {
            assert(allocator.resize(slice, math.ceilPowerOfTwo(usize, slice.len) catch unreachable));
        }

        /// Returns the index in the underlying buffer for a given logical element
        /// `index + addend`.
        fn wrapAdd(self: *Self, index: usize, addend: usize) usize {
            return wrap_index(index +% addend, self.capacity());
        }

        /// Returns the index in the underlying buffer for a given logical element
        /// `index - subtrahend`.
        fn wrapSub(self: *Self, index: usize, subtrahend: usize) usize {
            return wrap_index(index -% subtrahend +% self.capacity(), self.capacity());
        }

        fn toPhysicalIndex(self: *Self, index: usize) usize {
            return self.wrapAdd(self.head, index);
        }

        fn isFull(self: *Self) bool {
            return self.len == self.capacity();
        }

        /// The caller owns the returned memory. Empties this ArrayDeque.
        /// Its capacity is cleared, making deinit() safe but unnecessary to call.
        /// The returned memory may not be contiguous, use `makeContiguous` first
        /// or use `asSlices` to return both non-contiguous slices
        pub fn toOwnedSlice(self: *Self, allocator: Allocator) Allocator.Error!Slice {
            const old_memory = self.items;
            //if (allocator.resize(old_memory, new_n: usize))
            self.init(allocator);
            return old_memory;
        }

        /// The size of the underlying buffer
        pub fn capacity(self: *Self) usize {
            return self.items.len;
        }

        /// Returns the index just after the last occupied element
        fn tail(self: *Self) usize {
            return self.toPhysicalIndex(self.len);
        }

        /// Empties the deque without deallocating the backing slice.
        /// Invalidates all element pointers.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.len = 0;
            self.head = 0;
        }

        pub fn clearAndFree(self: *Self, allocator: Allocator) void {
            allocator.free(self.items);
            self.len = 0;
            self.head = 0;
        }

        /// Extend the deque by 1 element from the back. Allocates more memory as necessary.
        /// Invalidates pointers if additional memory is needed.
        pub fn append(self: *Self, allocator: Allocator, item: T) Allocator.Error!void {
            if (self.len == self.capacity()) try self.ensureTotalCapacity(allocator, @max(8, self.capacity() * 2));
            self.items[self.tail()] = item;
            self.len += 1;
        }

        /// Extend the deque by 1 element from the front. Allocates more memory as necessary.
        /// Invalidates pointers if additional memory is needed.
        pub fn prepend(self: *Self, allocator: Allocator, item: T) Allocator.Error!void {
            if (self.len == self.capacity()) try self.ensureTotalCapacity(allocator, @max(8, self.capacity() * 2));
            self.head = self.wrapSub(self.head, 1);
            self.len += 1;
            self.items[self.head] = item;
        }


        pub fn addOne(self: *Self, allocator: Allocator) Allocator.Error!*T {
            try self.ensureUnusedCapacity(allocator, 1);
            return self.addOneAssumeCapacity();
        }

        /// Increase length by 1, returning pointer to the new item.
        /// Asserts that there is already space for the new item without allocating more.
        /// The returned pointer becomes invalid when the list is resized.
        /// **Does not** invalidate element pointers.
        pub fn addOneAssumeCapacity(self: *Self) *T {
            assert(self.len < self.capacity());
            const result = &self.items[self.tail()];
            self.len += 1;
            return result;
        }

        pub fn addManyAsArrayAssumeCapacity(self: *Self, comptime n: usize) *[n]T {
            assert(self.tail() + n <= self.capacity());
            const old_end = self.tail();
            self.len += n;
            return self.items[old_end..][0..n];
        }

        // pub fn addManyAsSlice(self: *Self, allocator: Allocator, comptime n: usize) Allocator.Error![]T {

        // }

        /// Append the slice of items to the deque.
        /// Allocates more memory as necessary.
        /// Invalidates pointers if additional memory is needed.
        pub fn appendSlice(self: *Self, items: []const T) Allocator.Error!void {
            try self.ensureUnusedCapacity(items.len);
            const slices = self.unusedCapacitySlices();
            assert(slices[0].len + slices[1].len >= items.len);
            self.appendSliceAssumeCapacity(items);
        }

        /// Append the slice of items to the deque, asserting the capacity is already
        /// enough to store the new items. **Does not** invalidate pointers.
        pub fn appendSliceAssumeCapacity(self: *Self, items: []const T) void {
            const old_len = self.len;
            const new_len = old_len + items.len;
            const slices = self.unusedCapacitySlices();
            const first_len = slices[0].len;
            const rest = items.len - first_len;
            assert(items.len <= slices[0].len + slices[1].len);
            assert(new_len <= self.capacity());
            self.len = new_len;
            @memcpy(slices[0][0..], items[0..first_len]);
            @memcpy(slices[1][0..rest], items[first_len..]);
            //@memcpy(self.items[self.end()..][0..items.len], items);
        }

        /// Creates a copy of this ArrayDeque, using the same allocator.
        /// The items will be laid out identically in memory to the current backing slice.
        /// To create a copy with contiguous data, use `cloneContiguous`.
        pub fn clone(self: Self, allocator: Allocator) Allocator.Error!Self {
            var cloned = try Self.initCapacity(allocator, self.capacity());
            cloned.appendSliceAssumeCapacity(self.items);
            return cloned;
        }

        /// Creates a copy of this ArrayDeque, using the same allocator.
        /// The items will be laid out contiguously from the start of the new backing slice.
        /// To create an exact copy, use `clone`.
        pub fn cloneContiguous(self: Self, allocator: Allocator) Allocator.Error!Self {
            var cloned = try Self.initCapacity(allocator, self.capacity());
            const slice1, const slice2 = self.asSlices();
            cloned.appendSliceAssumeCapacity(slice1);
            cloned.appendSliceAssumeCapacity(slice2);
            return cloned;
        }

        /// Returns the element at `index` with respect to the first element
        /// and the capacity of the ArrayDeque.
        /// Asserts that the index is in-bounds, use `getOrNull` if an optional type is desired
        pub fn get(self: *Self, i: usize) *T {
            return &self.items[self.toPhysicalIndex(i)];
        }

        /// Returns the element at `index` with respect to the first element
        /// and the capacity of the ArrayDeque.
        /// If `index` is out of bounds, returns `null`.
        pub fn getOrNull(self: *Self, i: usize) ?*T {
            return if (i < self.len) &self.items[self.toPhysicalIndex(i)] else null;
        }

        /// Returns a pair of slices which contain, in order, the contents of the ArrayDeque
        /// if `makeContiguous` was previously called, all elements will be in the first slice
        /// and the second slice will be empty.
        pub fn asSlices(self: *Self) [2]Slice {
            return if (self.isContiguous())
                [2]Slice{self.items[self.head..self.toPhysicalIndex(self.len)], &.{}}
            else 
                [2]Slice{self.items[self.head..], self.items[0..self.toPhysicalIndex(self.len)]};
        }

        /// Returns whether the deque wraps around the end of the backing slice.
        fn isContiguous(self: *Self) bool {
            return self.head <= self.capacity() - self.len;
        }

        /// 
        pub fn ensureUnusedCapacity(self: *Self, allocator: Allocator, additional_count: usize) Allocator.Error!void {
            try self.ensureTotalCapacity(allocator, self.len + additional_count);
            assert(self.capacity() >= self.len + additional_count);
        }

        /// Increases the deque's length to match the full capacity that is already allocated.
        /// The new elements have `undefined` values. **Does not** invalidate pointers.
        pub fn expandToCapacity(self: *Self) void {
            self.len = self.capacity();
        }

        /// Rearranges the internal storage of the ArrayDeque so it is one contiguous slice, which is then returned.
        /// This does not allocate and does not return an owned Slice.
        /// The slice returned will start at `&self.buf[head]` and have a length of `self.len`
        pub fn asContiguousSlice(self: *Self) Slice {
            if (@sizeOf(T) == 0) {
                self.head = 0;
            }

            if (self.isContiguous()) {
                return self.items[self.head..self.head + self.len];
            }

            const cap, const len, const head = .{self.capacity(), self.len, self.head};
            const head_slice, const tail_slice = self.asSlices();

            const free = cap - len;
            const head_len = cap - head;
            const end = self.tail();

            if (free >= head_len) {
                // There is enough free space to hold from the head to the end of the slice
                // So first shift the tail to make enough space for the head
                // then copy the head to the correct position.
                // This is preferred because it puts the head at index 0
                //
                // from: DEFGH....ABC
                //   to: ABCDEFGH....
                //
                //    1: DEFGH....ABC
                mem.copyBackwards(T, self.items[head_len..], tail_slice);
                //    2: ...DEFGH.ABC
                mem.copyBackwards(T, self.items[0..head_len], head_slice);
                //    3: ABCDEFGH....

                self.head = 0;
            } else if (free >= end) {
                // There is enough free space to hold from the start of the slice to the tail
                // So first shift the head to make enough space for the tail
                // then copy the tail to the correct position.
                //
                // from: FGH....ABCDE
                //   to: ...ABCDEFGH.
                //
                //    1: FGH....ABCDE
                mem.copyForwards(T, self.items[end..], head_slice);
                //    2: FGHABCDE....
                mem.copyForwards(T, self.items[end + head_len..], tail_slice);
                //    3: ...ABCDEFGH.

                self.head = end;
            } else {
                // `free` is smaller than both `head_len` and `tail_len`.
                // Move the smaller slice to close the gap, then rotate until the head is in front
                if (head_len > end) {
                    // if there is no free space in the buffer, the slices are already next to each other
                    if (free != 0) {
                        mem.copyBackwards(T, self.items[free..], tail_slice);
                    }
                    self.head = free;
                } else {
                    if (free != 0) {
                        mem.copyForwards(T, self.items[end..], head_slice);
                    }
                    self.head = 0;
                }
                mem.rotate(T, self.items[self.head..self.head + len], end);
            }
            return self.items[self.head..self.head + len];
        }

        /// Makes the deque fully contiguous and ensures that it starts
        /// at the beginning of the backing slice.
        /// The slice returned is the length of the deque, not its capacity.
        pub fn asFullyContiguousSlice(self: *Self) Slice {
            if (!self.isContiguous()) {
                _ = self.asContiguousSlice();
            }
            if (self.head != 0) {
                mem.copyForwards(T, self.items[0..], self.items[self.head..self.tail()]);
                self.head = 0;
            }
            return self.items[0..self.len];
        }

        /// Returns a slice of all the unused capacity from the tail 
        /// to the head or the end of the buffer, whichever comes first.
        /// In other words, if the deque is contiguous but `head`
        /// is not zero, the buffer from 0..head will not be part of,
        pub fn unusedCapacitySlice(self: Self) [2]Slice {
            if (self.head == 0) {
                return self.items[self.len..];
            }
            return self.items[self.capacity() - (self.len - self.head)..self.head];
        }

        /// Returns slices containing the unused capacity of the deque.
        /// The first slice will always contain the slice 
        /// starting after the end of the deque.
        /// The second slice will contain the unused slice starting at index 0.
        /// If the slice is not contiguous or the head is at 0,
        /// the second slice will be empty
        pub fn unusedCapacitySlices(self: *Self) [2]Slice {
            return if (!self.isContiguous())
                [2]Slice{self.items[self.tail()..self.head], &.{}}
            else
                [2]Slice{self.items[self.head + self.len..], self.items[0..self.head]};
        }

        /// Remove and return the first element from the deque.
        /// Asserts the deque has at least one item.
        /// Invalidates pointers to first element.
        pub fn popFront(self: *Self) T {
            const result = self.items[self.head];
            self.head = (self.head + 1) & (self.capacity() - 1);
            self.len -= 1;
            return result;
        }

        /// Remove and return the first element from the deque.
        /// If the deque is empty, returns `null`.
        /// Invalidates pointers to first element.
        pub fn popFrontOrNull(self: *Self) ?T {
            if (self.len == 0) return null;
            return self.popFront();
        }

        /// Remove and return the last element from the deque.
        /// Asserts the deque has at least one item.
        /// Invalidates pointers to last element.
        pub fn popBack(self: *Self) T {
            self.len -= 1;
            return self.items[self.tail()];
        }

        /// Remove and return the last element from the deque.
        /// If the deque is empty, returns `null`.
        /// Invalidates pointers to last element.
        pub fn popBackOrNull(self: *Self) ?T {
            if (self.len == 0) return null;
            return self.popBack();
        }

        // pub fn swap(self: *Self, i: usize, j: usize) void {

        // }

        /// Removes the element at the specified index and returns it.
        /// The empty slot is filled from the end of the deque
        /// Invalidates pointers to last element.
        /// This operation is O(1).
        pub fn swapRemoveFront(self: *Self, i: usize) T {
            const len = self.len;
            if (i < len and i )
            if (i == 0) return self.popFront();
            if (i == self.len - 1) return self.popBack();
        }

        /// Removes the element at the specified index and returns it.
        /// The empty slot is filled from the end of the deque
        /// Invalidates pointers to last element.
        /// This operation is O(1).
        pub fn swapRemoveBack(self: *Self, i: usize) T {
            if (i == 0) return self.popFront();
            if (i == self.len - 1) return self.popBack();
        }

        fn resize(self: *Self) bool {
            return self.allocator.resize(self.items, @max(8, self.items.len *% 2));
        }

        // fn grow(self: *Self, allocator: Allocator) Allocator.Error!void {
        //     if (self.resize()) return;
        //     try self.ensureTotalCapacity(@max(8, self.items.len *% 2));
        // }

        /// Modify the array so that it can hold `new_capacity` items.
        /// If an additional allocation is required, the backing buffer size
        /// will be doubled, 
        pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, new_capacity: usize) Allocator.Error!void {
            if (self.capacity() >= new_capacity) return;

            if (@sizeOf(T) == 0) {
                self.items.len = math.maxInt(usize);
                return;
            }

            const maybe_capacity = math.ceilPowerOfTwo(usize, new_capacity) catch return Allocator.Error.OutOfMemory;
            const good_capacity = @max(maybe_capacity, 8);

            if (allocator.resize(self.items, good_capacity)) return;
            const new_memory = try allocator.alignedAlloc(T, alignment, good_capacity);
            const head_len = self.capacity() - self.head;
            @memcpy(new_memory[0..head_len], self.items[self.head..]);
            @memcpy(new_memory[head_len..self.len], self.items[0..self.tail()]);
            allocator.free(self.items);
            self.items = new_memory;
            self.head = 0;
        }

        fn copy(self: *Self, source: usize, dest: usize, len: usize) void {
            assert(dest + len <= self.capacity);
            assert(source + len <= self.capacity);
            const func = if (dest > source) mem.copyBackwards else mem.copyForwards;
            func(self.items[dest..dest + len], self.items[source..source + len]);
        }

        pub const Iterator = struct {
            front_index: usize,
            back_index: usize,
            dq: *const Self,
            
            pub fn next(it: *Iterator) ?*T {
                assert(it.index <= it.dq.items.len);
                const value = it.dq.getOrNull(it.front_index);
                it.index = it.dq.wrapAdd(it.index, 1);
                return value;
            }

            pub fn nextBack(it: *Iterator) ?*T {
                assert(it.index <= it.dq.items.len);
                it.back_index = it.dq.wrapSub(it.index, 1);
                return it.dq.getOrNull(it.back_index);
            }
        };

        /// Create a double ended iterator over pointers to the values in the deque.
        /// The iterator is invalidated if the map is modified.
        pub fn iterator(self: *Self) Iterator {
            return Iterator{
                .dq = self,
                .front_index = self.head,
                .back_index = self.tail(),
            };
        }
    };
}

test "ArrayDeque.init" {
    {
        var dq = ArrayDeque(i32).init(testing.allocator);
        defer dq.deinit();

        try testing.expect(dq.len == 0);
        try testing.expect(dq.capacity() == 0);
    }
}

test "ArrayDeque.initCapacity" {
    const a = testing.allocator;
    {
        var dq = try ArrayDeque(i8).initCapacity(a, 200);
        defer dq.deinit();
        try testing.expect(dq.len == 0);
        try testing.expect(dq.capacity() == 256);
    }
}

test "ArrayDeque.append/prepend/get" {
    const a = testing.allocator;
    {
        var dq = ArrayDeque(i32).init(a);
        defer dq.deinit();

        try dq.append(1);
        try testing.expectEqual(dq.len, 1);
        try testing.expectEqual(dq.capacity(), 8);
        try testing.expectEqual(dq.getOrNull(0), 1);
        try testing.expectEqual(dq.getOrNull(1), null);
        try testing.expectEqual(dq.end(), 1);

        try dq.prepend(2);
        try dq.prepend(3);
        try testing.expectEqual(dq.len, 3);
    }
}

test "ArrayDeque.asContiguousSlice/asFullyContiguousSlice" {
    const a = testing.allocator;
    {
        var dq = try ArrayDeque(i32).initCapacity(a, 16);
        defer dq.deinit();

        try dq.append(7);
        try dq.append(8);
        try dq.append(9);
        try dq.append(10);

        try dq.prepend(6);
        try dq.prepend(5);
        try dq.prepend(4);
        try dq.prepend(3);
        try dq.prepend(2);
        try dq.prepend(1);
        try dq.prepend(0);

        const arr = [_]i32{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10};

        try testing.expect(mem.eql(i32, arr[0..7], dq.items[dq.head..]));
        try testing.expect(mem.eql(i32, arr[7..], dq.items[0..dq.end()]));
        try testing.expect(mem.eql(i32, &arr, dq.asContiguousSlice()));
        try testing.expect(!mem.eql(i32, &arr, dq.items[0..11]));
        try testing.expect(mem.eql(i32, &arr, dq.asFullyContiguousSlice()));
        try testing.expect(mem.eql(i32, &arr, dq.items[0..11]));
    }
}

test "ArrayDeque.appendSlice" {
    const a = testing.allocator;
    {
        var dq = try ArrayDeque(i32).initCapacity(a, 10);
        defer dq.deinit();

        for (0..5) |_| {
            try dq.prepend(0);
        }
        for (0..5) |_| {
            _ = dq.popBack();
        }
        try testing.expect(dq.isContiguous());
        const nums = [_]i32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
        const unused = dq.unusedCapacitySlices();
        try testing.expect(unused[0].len + unused[1].len + dq.len == dq.capacity());
        //try dq.ensureTotalCapacity(10);
        try dq.appendSlice(&nums);
        const slices = dq.asSlices();
        try testing.expectEqualSlices(i32, nums[0..5], slices[0]);
        try testing.expectEqualSlices(i32, nums[5..], slices[1]);
    }
}