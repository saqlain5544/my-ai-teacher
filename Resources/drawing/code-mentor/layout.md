---
name: layout
summary: A type's memory layout: fields at their offsets, the padding between them, size and alignment.
aliases: memlayout, struct-layout, memory-layout
order: 140
---
Take every number from the compiler (`offsetof`, `sizeof`, `alignof`; `std::mem::offset_of!`; `@offsetOf`), never from your head:

```layout
{"name": "struct Packet (C, x86-64)", "size": 24, "align": 8,
 "fields": [{"name": "flag", "type": "char", "offset": 0, "size": 1},
            {"name": "id", "type": "uint64_t", "offset": 8, "size": 8},
            {"name": "len", "type": "uint16_t", "offset": 16, "size": 2}],
 "note": "Ordered id, len, flag it takes 16 bytes."}
```

The app draws the bytes as a bar and a table, and works out the padding (the gaps and the tail) and its share. Fields: `name`, `size`, `align`, `fields` (`name`, `type`, `offset`, `size`), optional `note`.
