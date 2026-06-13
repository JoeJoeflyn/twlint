// Re-export module — all rule logic lives in src/rules/*.zig
// Only symbols actually consumed by fixer.zig (the sole external consumer)
// are re-exported here. Rule sub-files import each other directly.
const common = @import("rules/common.zig");
const duplicates = @import("rules/duplicates.zig");
const conflicts = @import("rules/conflicts.zig");
const sorting = @import("rules/sorting.zig");
const invalid = @import("rules/invalid.zig");

pub const Issue = common.Issue;
pub const transformDuplicates = duplicates.transformDuplicates;
pub const transformConflicts = conflicts.transformConflicts;
pub const transformSorting = sorting.transformSorting;
pub const transformInvalidClasses = invalid.transformInvalidClasses;

// When compiled for tests, include the rule test suite.
comptime {
    if (@import("builtin").is_test) {
        _ = @import("rules/tests.zig");
    }
}
