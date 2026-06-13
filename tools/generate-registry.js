// tools/generate-registry.js
//
// Build-time generator: queries the official Tailwind CSS v4 IntelliSense
// design system and emits a Zig source file containing:
//   - static_classes:    every concrete utility class name (official source)
//   - all_prefixes:      functional utility prefixes (for arbitrary-value validation)
//   - dynamic_prefixes:  prefixes that accept numeric/fraction suffixes
//   - color_prefixes:    prefixes whose completions include color values
//   - spacing_prefixes:  prefixes whose completions include spacing/px values
//   - v3_to_v4_rewrites: necessary v3 → v4 rename mappings (old names removed in v4)
//
// Invoked by build.zig via `node tools/generate-registry.js`.

import { __unstable__loadDesignSystem } from "@tailwindcss/node";
import { writeFileSync } from "node:fs";

console.error("Generating Tailwind v4 registry from official IntelliSense...");

const design = await __unstable__loadDesignSystem('@import "tailwindcss";', {
  base: process.cwd(),
});

// 1. All currently valid classes (official source)
const static_classes = design.getClassList().map(([name]) => name).sort();

// 2. Functional prefixes (for arbitrary values like bg-[color])
const prefixes = new Set();
for (const utility of design.utilities.keys("functional")) {
  prefixes.add(utility + "-");
}

// 3. Dynamic prefixes (support numbers/fractions like p-4, w-1/2)
const dynamic_prefixes = new Set();
for (const utility of design.utilities.keys("functional")) {
  const completions = design.utilities.getCompletions(utility);
  if (completions.some(group => group.values.some(v => v && /\d/.test(v)))) {
    dynamic_prefixes.add(utility + "-");
  }
}

// 4. Color prefixes — prefixes whose completions include color-like values.
//    Detected by checking if any completion value contains a color keyword.
//    Used by css_theme.zig to generate classes from --color-* vars.
const color_keywords = new Set([
  "inherit", "current", "transparent", "black", "white",
  "red", "orange", "amber", "yellow", "lime", "green", "emerald",
  "teal", "cyan", "sky", "blue", "indigo", "violet", "purple",
  "fuchsia", "pink", "rose", "slate", "gray", "zinc", "neutral", "stone",
]);
const color_prefixes = new Set();
for (const utility of design.utilities.keys("functional")) {
  const completions = design.utilities.getCompletions(utility);
  const isColor = completions.some(group =>
    group.values.some(v => {
      if (!v) return false;
      return color_keywords.has(v) || color_keywords.has(v.split("-")[0]);
    })
  );
  if (isColor) {
    color_prefixes.add(utility + "-");
  }
}

// 5. Spacing prefixes — prefixes whose completions include numeric spacing values.
//    Used by css_theme.zig to generate classes from --spacing-* vars.
const spacing_values = new Set(["0", "px", "0.5", "1", "1.5", "2", "2.5", "3", "4", "5", "6", "8", "10", "12", "16", "20", "24", "32", "auto"]);
const spacing_prefixes = new Set();
for (const utility of design.utilities.keys("functional")) {
  const completions = design.utilities.getCompletions(utility);
  const isSpacing = completions.some(group =>
    group.values.some(v => v && spacing_values.has(v))
  );
  if (isSpacing) {
    spacing_prefixes.add(utility + "-");
  }
}

// 6. v3 → v4 Rewrites — extracted dynamically from official Tailwind v4
// canonicalizeCandidates API. We test known v3 class names and record any
// that get rewritten to a different canonical form.
//
// NOTE: canonicalizeCandidates does NOT handle the v3→v4 "breaking" renames
// where the old name still exists in v4 with a different meaning
// (shadow-sm→shadow-xs, rounded-sm→rounded-xs, etc.). Those are added manually
// below as they are semantic renames, not syntax modernizations.
const v3_class_names = [
  // Classes removed/renamed in v4 (canonicalizeCandidates handles these)
  "overflow-ellipsis", "decoration-slice", "decoration-clone",
  "flex-shrink", "flex-shrink-0", "flex-grow", "flex-grow-0",
  "bg-gradient-to-r", "bg-gradient-to-l", "bg-gradient-to-t", "bg-gradient-to-b",
  "bg-gradient-to-tr", "bg-gradient-to-tl", "bg-gradient-to-br", "bg-gradient-to-bl",
];

// Breaking renames: old name still exists in v4 but with different meaning.
// These MUST be manual — canonicalizeCandidates won't catch them.
const breaking_renames = {
  "shadow-sm": "shadow-xs",
  "shadow": "shadow-sm",
  "drop-shadow-sm": "drop-shadow-xs",
  "drop-shadow": "drop-shadow-sm",
  "blur-sm": "blur-xs",
  "blur": "blur-sm",
  "backdrop-blur-sm": "backdrop-blur-xs",
  "backdrop-blur": "backdrop-blur-sm",
  "rounded-sm": "rounded-xs",
  "rounded": "rounded-sm",
  "outline-none": "outline-hidden",
  "ring": "ring-3",
};

// Build rewrite table: canonicalizeCandidates for syntax modernizations
// + manual breaking renames for semantic changes
const v3_to_v4 = { ...breaking_renames };
for (const cls of v3_class_names) {
  const canonical = design.canonicalizeCandidates([cls])[0];
  if (canonical && canonical !== cls) {
    v3_to_v4[cls] = canonical;
  }
}

// --- Escape helper ---
function esc(s) {
  return s.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

// --- Emit Zig source ---
let out = "";

out += `// Generated from official Tailwind v4 at ${new Date().toISOString()}\n`;
out += `// DO NOT EDIT — regenerate with: node tools/generate-registry.js\n\n`;

out += `pub const static_classes = [_][]const u8{\n`;
for (const cls of static_classes) {
  out += `    "${esc(cls)}",\n`;
}
out += `};\n\n`;

out += `pub const all_prefixes = [_][]const u8{\n`;
for (const p of Array.from(prefixes).sort()) {
  out += `    "${esc(p)}",\n`;
}
out += `};\n\n`;

out += `pub const dynamic_prefixes = [_][]const u8{\n`;
for (const p of Array.from(dynamic_prefixes).sort()) {
  out += `    "${esc(p)}",\n`;
}
out += `};\n\n`;

out += `pub const color_prefixes = [_][]const u8{\n`;
for (const p of Array.from(color_prefixes).sort()) {
  out += `    "${esc(p)}",\n`;
}
out += `};\n\n`;

out += `pub const spacing_prefixes = [_][]const u8{\n`;
for (const p of Array.from(spacing_prefixes).sort()) {
  out += `    "${esc(p)}",\n`;
}
out += `};\n\n`;

out += `pub const v3_to_v4_rewrites = [_]struct { v3: []const u8, v4: []const u8 }{\n`;
for (const [v3, v4] of Object.entries(v3_to_v4)) {
  out += `    .{ .v3 = "${esc(v3)}", .v4 = "${esc(v4)}" },\n`;
}
out += `};\n`;

const outPath = "src/generated_registry.zig";
writeFileSync(outPath, out);

console.error(`✓ Generated ${static_classes.length} classes, ${prefixes.size} prefixes, ${dynamic_prefixes.size} dynamic, ${color_prefixes.size} color, ${spacing_prefixes.size} spacing prefixes, ${Object.keys(v3_to_v4).length} rewrites → ${outPath}`);
