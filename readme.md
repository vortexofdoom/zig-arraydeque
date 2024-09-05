# zig-arraydeque

An implementation of a double-ended array-backed deque in Zig, backed by a growable ring buffer.

## What does this offer that Zig's standard library doesn't?

The Zig standard library is missing a cache-friendly generic FIFO data structure with O(1) push/pop. `std.DoublyLinkedList` and `std.PriorityQueue` both offer 2/3 of these benefits, but `DoublyLinkedList` is not cache-friendly and `PriorityQueue` has O(logN) push/pop, as well as requiring insertion order to be saved alongside the items to maintain a FIFO structure.

A natural solution to this deficiency is a growable ring buffer in a contiguous slice of memory. At only a slight cost compared to `std.ArrayList`, O(1) (amortized) push on both ends can be achieved, and items can be accessed with only simple arithmetic and indexing, rather than the O(N) pointer chasing of a linked list.

This library aims to be a robust implementation of such a data structure, drawing heavily from Rust's [`VecDeque`](https://doc.rust-lang.org/1.81.0/src/alloc/collections/vec_deque/mod.rs.html) internally, and taking API/semantic cues from Zig's `std.ArrayList` (for append/pop/slice and similar methods) and `std.ArrayHashMap` (for iteration and internal buffer management.)
