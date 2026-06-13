import { __unstable__loadDesignSystem } from "@tailwindcss/node";
import { promises as fs } from "node:fs";
import path from "node:path";

const SKIP_DIRS = new Set([
  ".git",
  ".next",
  ".output",
  "build",
  "coverage",
  "dist",
  "node_modules",
  "target",
]);

const ENTRY_PATTERNS = [
  /@import\s+["']tailwindcss["']/,
  /@tailwind\s+(base|components|utilities)\b/,
  /@config\b/,
  /@plugin\b/,
];

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

function toProjectRelativePath(baseDir, fullPath) {
  return path.relative(baseDir, fullPath).split(path.sep).join("/");
}

async function walkCssFiles(baseDir) {
  const entryCssFiles = [];
  const themeOnlyCssFiles = [];

  async function visit(dir) {
    const entries = await fs.readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.name.startsWith(".")) continue;
      if (entry.isDirectory()) {
        if (SKIP_DIRS.has(entry.name)) continue;
        await visit(path.join(dir, entry.name));
        continue;
      }
      if (!entry.isFile() || !entry.name.endsWith(".css")) continue;

      const fullPath = path.join(dir, entry.name);
      const content = await fs.readFile(fullPath, "utf8");
      const relativePath = toProjectRelativePath(baseDir, fullPath);

      if (ENTRY_PATTERNS.some((pattern) => pattern.test(content))) {
        entryCssFiles.push(relativePath);
      } else if (content.includes("@theme")) {
        themeOnlyCssFiles.push(relativePath);
      }
    }
  }

  await visit(baseDir);
  entryCssFiles.sort();
  themeOnlyCssFiles.sort();
  return { entryCssFiles, themeOnlyCssFiles };
}

function importCss(relativePath) {
  return `@import "./${relativePath.replaceAll("\\", "/")}";`;
}

function buildDesignSources(entryCssFiles, themeOnlyCssFiles) {
  const sources = [];

  if (entryCssFiles.length > 0) {
    for (const file of entryCssFiles) {
      sources.push({
        entry: file,
        css: importCss(file),
      });
    }
  } else if (themeOnlyCssFiles.length > 0) {
    sources.push({
      entry: "<theme-fallback>",
      css: ['@import "tailwindcss";', ...themeOnlyCssFiles.map(importCss)].join("\n"),
    });
  } else {
    sources.push({
      entry: "<default>",
      css: '@import "tailwindcss";',
    });
  }

  return sources;
}

async function loadDesignSystems(baseDir) {
  const { entryCssFiles, themeOnlyCssFiles } = await walkCssFiles(baseDir);
  const sources = buildDesignSources(entryCssFiles, themeOnlyCssFiles);

  const designs = [];
  const errors = [];
  for (const source of sources) {
    try {
      const design = await __unstable__loadDesignSystem(source.css, { base: baseDir });
      designs.push({ entry: source.entry, design });
    } catch (error) {
      errors.push(`${source.entry}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  if (designs.length === 0) {
    const fallback = await __unstable__loadDesignSystem('@import "tailwindcss";', { base: baseDir });
    designs.push({ entry: "<default>", design: fallback });
  }

  return { designs, errors };
}

function collectRegistry(designs) {
  const classes = new Set();
  const prefixes = new Set();
  const dynamicPrefixes = new Set();

  for (const { design } of designs) {
    for (const [name] of design.getClassList()) classes.add(name);
    for (const utility of design.utilities.keys("functional")) {
      const prefix = `${utility}-`;
      prefixes.add(prefix);

      const completions = design.utilities.getCompletions(utility);
      const supportsDynamic = completions.some((group) =>
        group.values.some((value) => value && (/[\d/]/.test(value) || value === "px"))
      );
      if (supportsDynamic) dynamicPrefixes.add(prefix);
    }
  }

  return {
    classes: [...classes].sort(),
    prefixes: [...prefixes].sort(),
    dynamicPrefixes: [...dynamicPrefixes].sort(),
  };
}

function resolveCandidate(designs, candidate) {
  let canonical = null;
  let valid = false;

  for (const { design } of designs) {
    let nextCanonical = null;
    try {
      // The standalone resolver is the slow but precise fallback path, so we
      // still ask Tailwind for canonical rewrites here.
      nextCanonical = design.canonicalizeCandidates([candidate])[0] ?? null;
      if (canonical === null && nextCanonical && nextCanonical !== candidate) {
        canonical = nextCanonical;
      }
    } catch {}

    try {
      const css = design.candidatesToCss([candidate])[0];
      if (css !== null) {
        valid = true;
        if (nextCanonical && nextCanonical !== candidate) canonical = nextCanonical;
        break;
      }
    } catch {}

    if (nextCanonical && nextCanonical !== candidate) {
      try {
        const css = design.candidatesToCss([nextCanonical])[0];
        if (css !== null) {
          valid = true;
          canonical = nextCanonical;
          break;
        }
      } catch {}
    }
  }

  return {
    candidate,
    valid,
    canonical,
  };
}

function parseRequest(rawInput) {
  const input = rawInput.trim().length > 0 ? JSON.parse(rawInput) : {};
  return {
    baseDir: path.resolve(input.baseDir ?? process.cwd()),
    candidates: Array.isArray(input.candidates) ? [...new Set(input.candidates)] : [],
    includeRegistry: input.includeRegistry !== false,
  };
}

const rawInput = await readStdin();
const { baseDir, candidates, includeRegistry } = parseRequest(rawInput);

const { designs, errors } = await loadDesignSystems(baseDir);
const registry = includeRegistry ? collectRegistry(designs) : null;
const resolutions = candidates.map((candidate) => resolveCandidate(designs, candidate));

process.stdout.write(
  JSON.stringify({
    entries: designs.map(({ entry }) => entry),
    errors,
    classes: includeRegistry ? registry.classes : [],
    prefixes: includeRegistry ? registry.prefixes : [],
    dynamicPrefixes: includeRegistry ? registry.dynamicPrefixes : [],
    resolutions,
  })
);
