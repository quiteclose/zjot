# zjot

A Djot parser written in Zig. Provides both a library for programmatic use and a CLI for rendering Djot documents.

## References

This project applies lessons learned from a draft Zig implementation to produce a clean, modular parser with robust source position tracking and a proper public API.

The reference implementations used during development are:

- **djot.js** -- John MacFarlane's canonical JavaScript implementation (2-phase event stream to AST)
- **jotdown** -- Rust implementation (2-phase block events to inline events)

zjot uses a single-phase recursive descent approach: one pass builds the AST directly. This is simpler than the multi-phase designs and adequate for our needs.

## Architecture

```
src/
  root.zig           Library root: public API (toHtml, toAst, toAstOpts)
  main.zig           CLI binary (--ast, --sourcepos, file/stdin)
  node.zig           Node, Tag, Attr, SourcePos, CellAlign
  Parser.zig         Block parsing, sub-parser coordination, list helpers
  document.zig       Document-level state: Survey (ids, auto refs), Resolver, Sections
  inline.zig         Inline parsing (parseInlineContent + all handlers)
  attributes.zig     AttrParser state machine, BlockAttrs
  html.zig           HTML renderer
  ast.zig            AST renderer (indented text format matching djot.js)
  LineMap.zig         Source position mapping for inline content
  test_runner.zig    Test harness for .test files
test/
  *.test             Vendored djot.js test files (26 files, 261 test cases)
  cli/               CLI golden fixtures: NAME.dj with NAME.html, NAME.ast, NAME.sourcepos.ast
```

### Module responsibilities

- **root.zig** -- Public API. Exposes `toHtml`, `toAst`, `toAstOpts`. Creates a `Parser`, calls `document.parseDoc`, and renders the result.
- **node.zig** -- AST types. `Tag` enum (46 tags), `Node` struct with children, text, attributes, source positions. `Attr`, `SourcePos`, `CellAlign`.
- **Parser.zig** -- Block-level parsing, block-local: `nextBlock` yields one block at a time and never generates ids or resolves references. Owns `Definitions` (ref defs and footnote defs, allocated for the document's lifetime) shared by pointer with sub-parsers. Contains `parseBlocks`, `try*` block functions, unified list helpers (`collectItemContent`, `parseItemContent`), and LineMap-based inline position tracking.
- **document.zig** -- Document-level state, split by lifetime. `Survey` visits every block once and assigns heading ids (djot.js rule: document order, each generated id avoiding every id seen so far) and auto references. `Resolver` resolves one block at a time against the definitions and the survey (ids by ordinal, links by label, footnote numbers by first use) and builds the endnotes. `Sections` turns headings into open/close events without allocating. `parseDoc` drives the three into one tree.
- **inline.zig** -- Inline parsing. `parseInlineContent` with opener stack and `resolveItems`. Handlers for emphasis, links, smart quotes, super/subscript, insert/delete/mark, math, symbols, raw inline, autolinks.
- **attributes.zig** -- Attribute parsing. `AttrParser` state machine for `{#id .class key=value}` syntax. `BlockAttrs` struct. Block and inline attribute parsing entry points.
- **html.zig** -- HTML rendering. Walks the `Node` tree and produces HTML string output.
- **ast.zig** -- AST rendering. Walks the `Node` tree and produces indented text format matching djot.js test expectations.
- **LineMap.zig** -- Maps byte offsets in joined inline text back to original source positions. Uses segments with O(1) resolution per lookup. Built by `Parser.buildInlineLineMap` from content lines and their original positions.
- **test_runner.zig** -- Parses `.test` files (backtick-fenced input/output pairs) and runs them against the parser.

### Key design decisions

1. **Definitions by pointer, with their own allocator** -- Sub-parsers (for list items, blockquotes, etc.) receive a `*Definitions` pointer instead of copying hash maps in and out, so a definition inside a container is visible to the parent. Everything stored there is duped into `Definitions.a`, so definitions outlive the block that produced them whatever allocator the blocks use.

2. **LineMap for inline positions** -- When content lines are joined for inline parsing, `Parser.buildInlineLineMap` creates a `LineMap` with segments mapping joined offsets to original line/col/offset. After `parseInlineContent` returns, `applyInlinePositions` uses pointer arithmetic to find each `str` node's byte offset in the joined source (O(1) per node) and resolves it via the LineMap. No `indexOf`-based string searching.

3. **Unified list helpers** -- `collectItemContent` and `parseItemContent` are shared between bullet and ordered list parsing. `collectItemContent` handles para line collection (with sourcepos tracking arrays), block continuation after blanks (with `isNewBlockStart` lazy continuation), and trailing blank trimming. `parseItemContent` creates sub-parsers with correct sourcepos propagation and returns merged inner blocks. `updateListTightness` centralizes tightness detection.

4. **Proper error handling** -- Public API uses Zig error unions (`!` return types). The parser degrades gracefully on malformed input but propagates allocation failures.

5. **Exposed AST** -- The `Node` type is public so consumers like Wig can walk the tree directly rather than being limited to string output.

## Conventions

- **Author name:** "QuiteClose" in any content or documentation.
- **Session continuity:** This file is the primary context document. Read it first in any new session.
- **Pause-discuss-commit:** Each implementation step is explained and discussed before committing.
- **Test-driven:** The vendored djot.js test suite (261 cases across 26 files) drives development. All changes should maintain or increase the pass count.

## Test suite

Test files are vendored from `djot.js/test/` into `test/`. Each `.test` file contains backtick-fenced test cases:

```
` ` ` [options]
input
.
expected output
` ` `
```

Options: `a` = AST mode (compare against AST output instead of HTML), `p` = sourcepos (include source positions in AST).

Run tests: `zig build test`

Run them on WASI (needs wasmtime): `zig build test -Dtarget=wasm32-wasi -fwasmtime`

### CLI goldens

`zig build cli-test` runs the binary against `test/cli/`: one fixture per block family
(`hi`, `headings`, `inlines`, `lists`, `code`, `blockquote`, `table`, `footnotes`), each in
HTML, `--ast` and `--ast --sourcepos` mode, plus the stdin, `-`, option and error cases
written inline in `build.zig`. The goldens test the CLI path (argv to bytes on stdout, exit
code), not the parser; parser behaviour belongs in the `.test` suite.

To add a fixture: write `test/cli/NAME.dj`, generate the three expected files with the
binary and read them, then add `NAME` to `fixtures` in `build.zig` (in that order: the
build script reads every registered golden at configure time and stops on a missing one):

```
zig build
zig-out/bin/zjot test/cli/NAME.dj > test/cli/NAME.html
zig-out/bin/zjot --ast test/cli/NAME.dj > test/cli/NAME.ast
zig-out/bin/zjot --ast --sourcepos test/cli/NAME.dj > test/cli/NAME.sourcepos.ast
```

Regenerate the same way after an intended output change, and review the diff: the
expected files pin zjot's own output, so a regeneration accepts whatever the binary does.

## Implementation status

All 261 djot.js test cases pass. The parser is feature-complete for the Djot specification as tested by the canonical test suite. Source position tracking is implemented and verified.
