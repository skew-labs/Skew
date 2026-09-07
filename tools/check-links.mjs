import assert from "node:assert/strict";
import { access, readdir, readFile } from "node:fs/promises";
import { dirname, extname, join, resolve } from "node:path";

const root = resolve(new URL("..", import.meta.url).pathname);
const markdown = [];
async function walk(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (entry.name === ".git" || entry.name === "node_modules") continue;
    const path = join(directory, entry.name);
    if (entry.isDirectory()) await walk(path);
    else if (extname(entry.name) === ".md") markdown.push(path);
  }
}

await walk(root);
for (const file of markdown) {
  const source = await readFile(file, "utf8");
  for (const match of source.matchAll(/\[[^\]]+\]\(([^)]+)\)/g)) {
    const target = match[1].trim();
    if (/^(https?:|mailto:|#)/.test(target)) continue;
    const relative = decodeURIComponent(target.split("#", 1)[0].split("?", 1)[0]);
    if (!relative) continue;
    await assert.doesNotReject(access(resolve(dirname(file), relative)), `${file}: missing ${target}`);
  }
}

console.log(`Checked local links in ${markdown.length} Markdown files.`);
