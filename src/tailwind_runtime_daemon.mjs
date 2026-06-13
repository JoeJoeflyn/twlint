import { __unstable__loadDesignSystem } from "@tailwindcss/node";
import { promises as fs } from "node:fs";
import net from "node:net";
import path from "node:path";

const socketPath = process.env.TWLINT_DAEMON_SOCKET ?? "/tmp/twlint-tailwind.sock";
const idleMs = Number.parseInt(process.env.TWLINT_DAEMON_IDLE_MS ?? "600000", 10);

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

const projectCache = new Map();
const designSystemCache = new Map();
const namedValueCache = new WeakMap();
let idleTimer = null;
let activeRequests = 0;

function cacheKey(baseDir, projectHash) {
  return `${path.resolve(baseDir)}::${projectHash ?? "unhashed"}`;
}

function scheduleIdleExit() {
  if (activeRequests > 0) return;
  if (idleTimer !== null) clearTimeout(idleTimer);
  idleTimer = setTimeout(async () => {
    try {
      server.close();
    } finally {
      try {
        await fs.rm(socketPath, { force: true });
      } catch {}
      process.exit(0);
    }
  }, idleMs);
  idleTimer.unref?.();
}

function beginRequest() {
  activeRequests += 1;
  if (idleTimer !== null) {
    clearTimeout(idleTimer);
    idleTimer = null;
  }
}

function finishRequest(socket, payload) {
  socket.end(payload, () => {
    activeRequests = Math.max(0, activeRequests - 1);
    scheduleIdleExit();
  });
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

const THEME_CANONICAL_SPECS = [
  { property: "color", root: "text", namespace: "--color-" },
  { property: "background-color", root: "bg", namespace: "--color-" },
  { property: "border-color", root: "border", namespace: "--color-" },
  { property: "border-top-color", root: "border-t", namespace: "--color-" },
  { property: "border-right-color", root: "border-r", namespace: "--color-" },
  { property: "border-bottom-color", root: "border-b", namespace: "--color-" },
  { property: "border-left-color", root: "border-l", namespace: "--color-" },
  { property: "outline-color", root: "outline", namespace: "--color-" },
  { property: "caret-color", root: "caret", namespace: "--color-" },
  { property: "accent-color", root: "accent", namespace: "--color-" },
  { property: "fill", root: "fill", namespace: "--color-" },
  { property: "stroke", root: "stroke", namespace: "--color-" },
  {
    property: "text-decoration-color",
    root: "decoration",
    namespace: "--color-",
  },
];

function canonicalSpec(candidate) {
  if (candidate.kind === "arbitrary" && candidate.modifier === null) {
    return THEME_CANONICAL_SPECS.find(
      ({ property }) => property === candidate.property
    );
  }

  if (
    candidate.kind === "functional" &&
    candidate.modifier === null &&
    candidate.value?.kind === "arbitrary"
  ) {
    return THEME_CANONICAL_SPECS.find(({ root }) => root === candidate.root);
  }

  return null;
}

function declarationSignature(css) {
  const properties = new Set();
  for (const line of css.split("\n")) {
    const match = /^\s*([-\w]+):/.exec(line);
    if (!match || match[1].startsWith("--")) continue;
    properties.add(match[1]);
  }
  return [...properties].sort().join("\0");
}

function findUniqueThemeName(design, namespace, value) {
  let match = null;
  for (const [key, themeValue] of design.theme.entries()) {
    if (!key.startsWith(namespace) || themeValue.value !== value) continue;

    const name = key.slice(namespace.length);
    if (name.length === 0 || match !== null) return null;
    match = name;
  }
  return match;
}

function fastCanonicalizeThemeCandidate(design, rawCandidate, sourceCss) {
  let parsedCandidates = [];
  try {
    parsedCandidates = design.parseCandidate(rawCandidate);
  } catch {
    return null;
  }
  if (parsedCandidates.length !== 1) return null;

  const parsed = parsedCandidates[0];
  const spec = canonicalSpec(parsed);
  if (!spec) return null;

  const value =
    parsed.kind === "arbitrary" ? parsed.value : parsed.value.value;
  const themeName = findUniqueThemeName(
    design,
    spec.namespace,
    value
  );
  if (themeName === null) return null;

  const replacement = design.printCandidate({
    kind: "functional",
    root: spec.root,
    modifier: null,
    value: { kind: "named", value: themeName, fraction: null },
    variants: parsed.variants,
    important: parsed.important,
    raw: rawCandidate,
  });

  let replacementCss = null;
  try {
    replacementCss = design.candidatesToCss([replacement])[0];
  } catch {
    return null;
  }
  if (replacementCss === null || replacementCss === undefined) return null;

  return declarationSignature(sourceCss) === declarationSignature(replacementCss)
    ? replacement
    : null;
}

function parseDeclarations(css) {
  const declarations = new Map();
  for (const line of css.split("\n")) {
    const match = /^\s*([-\w]+):\s*(.+);\s*$/.exec(line);
    if (!match || match[1].startsWith("--")) continue;
    declarations.set(match[1], match[2]);
  }
  return declarations;
}

function resolveThemeVariables(design, value) {
  let resolved = value;
  for (let pass = 0; pass < 8; pass++) {
    let changed = false;
    resolved = resolved.replace(
      /var\((--[\w-]+)(?:,\s*([^()]*))?\)/g,
      (match, name, fallback) => {
        const themeValue = design.theme.get([name]);
        const replacement = themeValue ?? fallback?.trim();
        if (!replacement) return match;
        changed = true;
        return replacement;
      }
    );
    if (!changed) break;
  }
  return resolved;
}

function normalizeNumericCssValue(design, value) {
  const resolved = resolveThemeVariables(design, value)
    .trim()
    .replace(/\s+/g, " ");

  const dimension = /^(-?\d*\.?\d+)(px|rem|%)$/.exec(resolved);
  if (dimension) {
    const number = Number.parseFloat(dimension[1]);
    const unit = dimension[2];
    if (unit === "rem") return { number: number * 16, unit: "px" };
    return { number, unit };
  }
  if (resolved === "0") return { number: 0, unit: "px" };

  const inner =
    resolved.startsWith("calc(") && resolved.endsWith(")")
      ? resolved.slice(5, -1).trim()
      : resolved;

  let match = /^(-?\d*\.?\d+)(px|rem|%)\s*\*\s*(-?\d*\.?\d+)$/.exec(inner);
  if (match) {
    const left = normalizeNumericCssValue(design, `${match[1]}${match[2]}`);
    return left
      ? { number: left.number * Number.parseFloat(match[3]), unit: left.unit }
      : null;
  }

  match = /^(-?\d*\.?\d+)\s*\*\s*(-?\d*\.?\d+)(px|rem|%)$/.exec(inner);
  if (match) {
    const right = normalizeNumericCssValue(design, `${match[2]}${match[3]}`);
    return right
      ? { number: Number.parseFloat(match[1]) * right.number, unit: right.unit }
      : null;
  }

  match =
    /^(-?\d*\.?\d+)\s*\/\s*(-?\d*\.?\d+)\s*\*\s*100%$/.exec(inner);
  if (match) {
    return {
      number:
        (Number.parseFloat(match[1]) / Number.parseFloat(match[2])) * 100,
      unit: "%",
    };
  }

  return null;
}

function cssValuesEqual(design, left, right) {
  const normalizedLeft = normalizeNumericCssValue(design, left);
  const normalizedRight = normalizeNumericCssValue(design, right);
  if (normalizedLeft && normalizedRight) {
    return (
      normalizedLeft.unit === normalizedRight.unit &&
      Math.abs(normalizedLeft.number - normalizedRight.number) < 0.0001
    );
  }
  return (
    resolveThemeVariables(design, left).trim() ===
    resolveThemeVariables(design, right).trim()
  );
}

function sourceDeclarationsMatch(design, sourceCss, namedCss) {
  const source = parseDeclarations(sourceCss);
  const named = parseDeclarations(namedCss);
  if (source.size === 0) return false;

  for (const [property, value] of source) {
    const namedValue = named.get(property);
    if (namedValue === undefined || !cssValuesEqual(design, value, namedValue)) {
      return false;
    }
  }
  return true;
}

function namedCandidateForValue(design, parsed, value) {
  let named = [];
  try {
    named = design.parseCandidate(
      value === null ? parsed.root : `${parsed.root}-${value}`
    );
  } catch {
    return null;
  }

  const candidate = named.find(
    (item) => item.kind === "functional" && item.root === parsed.root
  );
  if (!candidate) return null;

  return design.printCandidate({
    ...candidate,
    variants: parsed.variants,
    important: parsed.important,
  });
}

function declarationProperties(css) {
  return [...parseDeclarations(css).keys()].sort();
}

function propertySignature(properties) {
  return properties.join("\0");
}

function containsAllProperties(candidateCss, requiredProperties) {
  const properties = parseDeclarations(candidateCss);
  return requiredProperties.every((property) => properties.has(property));
}

function cachedNamedOptions(design, parsed, sourceCss) {
  let designCache = namedValueCache.get(design);
  if (!designCache) {
    designCache = new Map();
    namedValueCache.set(design, designCache);
  }

  const sourceProperties = declarationProperties(sourceCss);
  const cacheKey = `${parsed.root}\0${propertySignature(sourceProperties)}`;
  if (designCache.has(cacheKey)) return designCache.get(cacheKey);

  const baseParsed = {
    ...parsed,
    variants: [],
    important: false,
  };
  const values = [];
  const seen = new Set();

  for (const group of design.utilities.getCompletions(parsed.root)) {
    let groupMatchesProperties = false;
    // Completion groups are property-homogeneous except for occasional
    // default-plus-themed groups (for example `border` followed by colors).
    // Probe at most the first two values to identify the relevant property.
    for (const sampleValue of group.values.slice(0, 2)) {
      const sampleCandidate = namedCandidateForValue(
        design,
        baseParsed,
        sampleValue
      );
      if (sampleCandidate === null) continue;

      let sampleCss = null;
      try {
        sampleCss = design.candidatesToCss([sampleCandidate])[0];
      } catch {
        continue;
      }
      if (
        sampleCss !== null &&
        sampleCss !== undefined &&
        containsAllProperties(sampleCss, sourceProperties)
      ) {
        groupMatchesProperties = true;
        break;
      }
    }
    if (!groupMatchesProperties) continue;

    for (const value of group.values) {
      const key = value === null ? "<default>" : value;
      if (seen.has(key)) continue;
      seen.add(key);
      values.push(value);
    }
  }

  const candidates = [];
  const candidateValues = [];
  for (const value of values) {
    const candidate = namedCandidateForValue(design, baseParsed, value);
    if (candidate === null) continue;
    candidates.push(candidate);
    candidateValues.push(value);
  }

  let cssList = [];
  try {
    cssList = design.candidatesToCss(candidates);
  } catch {
    cssList = [];
  }

  const options = [];
  for (let index = 0; index < candidates.length; index++) {
    const css = cssList[index];
    if (css === null || css === undefined) continue;
    options.push({ value: candidateValues[index], css });
  }
  designCache.set(cacheKey, options);
  return options;
}

function fastNamedValueCandidate(design, rawCandidate, sourceCss) {
  let parsedCandidates = [];
  try {
    parsedCandidates = design.parseCandidate(rawCandidate);
  } catch {
    return null;
  }
  if (parsedCandidates.length !== 1) return null;

  const source = parsedCandidates[0];
  let parsed = source;

  if (source.kind === "arbitrary" && source.modifier === null) {
    const spec = canonicalSpec(source);
    if (!spec) return null;
    parsed = {
      kind: "functional",
      root: spec.root,
      modifier: null,
      value: { kind: "arbitrary", dataType: null, value: source.value },
      variants: source.variants,
      important: source.important,
      raw: rawCandidate,
    };
  } else if (
    source.kind !== "functional" ||
    source.modifier !== null ||
    source.value?.kind !== "arbitrary"
  ) {
    return null;
  }

  for (const option of cachedNamedOptions(design, parsed, sourceCss)) {
    if (!sourceDeclarationsMatch(design, sourceCss, option.css)) continue;

    const candidate = namedCandidateForValue(design, parsed, option.value);
    if (candidate === null) continue;

    // Tailwind completions are already ordered by the design system. When
    // several aliases generate the same value (for example w-1/2, w-2/4),
    // use the first official completion instead of maintaining our own table.
    return candidate;
  }
  return null;
}

/// Batch-resolve candidates across all designs using bulk API calls.
/// Candidates already in the registry's class set are skipped (known valid).
function resolveCandidatesBatch(designs, candidates, registryClasses) {
  if (candidates.length === 0) return [];

  const classSet = registryClasses ? new Set(registryClasses) : null;
  const results = new Array(candidates.length);
  const unknownIndices = [];

  for (let i = 0; i < candidates.length; i++) {
    const c = candidates[i];
    // Fast path: if the candidate is already in the registry, it's valid.
    if (classSet && classSet.has(c)) {
      results[i] = { candidate: c, valid: true, canonical: null };
      continue;
    }
    results[i] = { candidate: c, valid: false, canonical: null };
    unknownIndices.push(i);
  }

  // Only resolve unknown candidates through the expensive Tailwind API.
  if (unknownIndices.length === 0) return results;
  const unknownCandidates = unknownIndices.map((i) => candidates[i]);
  for (const { design } of designs) {
    let csses = [];
    try {
      csses = design.candidatesToCss(unknownCandidates);
    } catch {}

    let allResolved = true;
    for (let j = 0; j < unknownIndices.length; j++) {
      const i = unknownIndices[j];
      if (results[i].valid) continue;
      allResolved = false;

      if (csses[j] !== null && csses[j] !== undefined) {
        results[i].valid = true;

        results[i].canonical =
          fastCanonicalizeThemeCandidate(
            design,
            results[i].candidate,
            csses[j]
          ) ??
          fastNamedValueCandidate(
            design,
            results[i].candidate,
            csses[j]
          );
        continue;
      }
    }
    if (allResolved) break;
  }

  return results;
}

async function getOrLoadDesignSystems(baseDir, projectHash) {
  const key = cacheKey(baseDir, projectHash);
  if (designSystemCache.has(key)) return designSystemCache.get(key);

  // Cache the in-flight promise so concurrent requests do not each boot their
  // own Tailwind design system for the same project.
  const promise = loadDesignSystems(baseDir);
  designSystemCache.set(key, promise);
  return promise;
}

async function getProjectState(baseDir, projectHash, includeRegistry) {
  const key = cacheKey(baseDir, projectHash);
  if (projectHash !== null) {
    const cached = projectCache.get(key);
    if (cached) return cached;
  }

  const next = await getOrLoadDesignSystems(baseDir, projectHash);
  if (!includeRegistry) {
    return {
      projectHash,
      designs: next.designs,
      errors: next.errors,
      registry: null,
      entries: next.designs.map(({ entry }) => entry),
    };
  }

  const state = {
    projectHash,
    designs: next.designs,
    errors: next.errors,
    registry: collectRegistry(next.designs),
    entries: next.designs.map(({ entry }) => entry),
  };
  if (projectHash !== null) {
    projectCache.set(key, state);
  }
  return state;
}

function parseRequest(rawInput) {
  const input = rawInput.trim().length > 0 ? JSON.parse(rawInput) : {};
  return {
    baseDir: path.resolve(input.baseDir ?? process.cwd()),
    candidates: Array.isArray(input.candidates) ? [...new Set(input.candidates)] : [],
    includeRegistry: input.includeRegistry !== false,
    projectHash:
      typeof input.projectHash === "string" && input.projectHash.length > 0
        ? input.projectHash
        : null,
  };
}

function emptyResponse(error) {
  return {
    entries: [],
    errors: [error instanceof Error ? error.message : String(error)],
    classes: [],
    prefixes: [],
    dynamicPrefixes: [],
    resolutions: [],
  };
}

async function handleRequest(rawInput) {
  const { baseDir, candidates, includeRegistry, projectHash } = parseRequest(rawInput);

  const state = await getProjectState(baseDir, projectHash, includeRegistry);
  const resolutions = resolveCandidatesBatch(
    state.designs,
    candidates,
    state.registry?.classes ?? null
  );
  const response = {
    entries: state.entries,
    errors: state.errors,
    classes: includeRegistry ? state.registry.classes : [],
    prefixes: includeRegistry ? state.registry.prefixes : [],
    dynamicPrefixes: includeRegistry ? state.registry.dynamicPrefixes : [],
    resolutions,
  };
  return response;
}

const server = net.createServer({ allowHalfOpen: true }, (socket) => {
  socket.setEncoding("utf8");

  let data = "";
  socket.on("data", (chunk) => {
    data += chunk;
  });

  socket.on("end", async () => {
    beginRequest();
    try {
      const response = await handleRequest(data);
      finishRequest(socket, JSON.stringify(response));
    } catch (error) {
      finishRequest(socket, JSON.stringify(emptyResponse(error)));
    }
  });

  socket.on("error", () => {
    if (activeRequests > 0) {
      activeRequests -= 1;
      scheduleIdleExit();
    }
  });
});

server.on("error", async (error) => {
  if (error && typeof error === "object" && "code" in error && error.code === "EADDRINUSE") {
    // Check if the socket is actually alive — if not, it's stale and we can take over.
    const alive = await new Promise((resolve) => {
      const probe = net.connect(socketPath, () => { probe.end(); resolve(true); });
      probe.on("error", () => resolve(false));
    });
    if (alive) {
      try { await fs.rm(`${socketPath}.starting`, { force: true }); } catch {}
      process.exit(0);
    }
    // Stale socket — remove and retry.
    try { await fs.rm(socketPath, { force: true }); } catch {}
    server.listen(socketPath, () => { scheduleIdleExit(); });
    return;
  }

  try {
    await fs.rm(socketPath, { force: true });
  } catch {}
  process.exit(1);
});

async function cleanupAndExit(code) {
  try {
    await fs.rm(socketPath, { force: true });
    await fs.rm(`${socketPath}.starting`, { force: true });
  } catch {}
  process.exit(code);
}

process.on("SIGINT", () => {
  void cleanupAndExit(0);
});
process.on("SIGTERM", () => {
  void cleanupAndExit(0);
});

// We intentionally let listen() detect stale sockets instead of removing them
// up front. That keeps concurrent startup simple: one process wins the socket,
// the others exit after a quick liveness check.

const preloadBaseDir = process.env.TWLINT_DAEMON_BASE_DIR;
const preloadProjectHash = process.env.TWLINT_DAEMON_PROJECT_HASH ?? null;
if (preloadBaseDir) {
  getProjectState(
    path.resolve(preloadBaseDir),
    preloadProjectHash && preloadProjectHash.length > 0 ? preloadProjectHash : null,
    true
  ).catch(() => {});
}

server.listen(socketPath, () => {
  // The Zig side creates this marker before spawning the daemon so other
  // processes can wait instead of racing to start another copy.
  try { fs.rm(`${socketPath}.starting`, { force: true }); } catch {}
  scheduleIdleExit();
});
