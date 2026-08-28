package main
import "../search"

// The seam every caller uses, so nobody re-splits it their own way.
exclude_dirs :: proc(a: ^App, alloc := context.temp_allocator) -> []string {
    return search.exclude_split(a.exclude, alloc)
}
