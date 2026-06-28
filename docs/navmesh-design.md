# Navmesh evolution: explicit edges + adaptive resolution

**Status:** Proposed (design only — no implementation yet)
**Scope:** `ext/Client/ClientNavmeshBaker.lua`, `ext/Server/Navmesh.lua`, the helper navmesh tools, and the runtime consumer (future).
**Author/decision:** design discussion, 2026-06-28.

---

## 1. Summary

The in-game navmesh today is a **uniform voxel grid with implicit adjacency**. It bakes
well enough to visualize, but inspection (noclip fly-through) shows two structural
problems it *cannot* fix in its current form:

1. **Connections run through geometry** — adjacent cells get linked even when a wall sits
   between them.
2. **Resolution is uniform** — no way to add detail where it matters (doorways, cover,
   ledges) or coarsen wasteful open areas.

Both trace to one root cause: **adjacency is positional, not stored.** This doc proposes
moving connectivity to **explicit edges** (Phase 1), which fixes the geometry problem and
unlocks manual link/unlink and single-node editing — and then layering **quantized
(quadtree) variable resolution** on top (Phase 2) for adaptive detail.

The work is sequenced so Phase 1 ships real value on its own, and Phase 2 is a clean layer
on top rather than a rewrite.

---

## 2. How it works today

The bake (`ClientNavmeshBaker`) flood-fills the world on a horizontal grid, probing each
candidate cell with raycasts (downward floor probe + upward clearance + slope check + a
`MAX_STEP` height-continuity check). Walkable cells are stored as:

```
m_Cells["gx:gz:gy"] = { x, y, z, gx, gz, gy }
```

- `gx, gz = floor(world / cellSize)` — one global `cellSize`, snapshotted per bake/load.
- `gy = floor(y / VERTICAL_RESOLUTION)` — separates stacked surfaces (bridges, floors).

**There are no stored links.** Adjacency is recomputed on the fly wherever it's needed:

- Overlay draws lines to the `gx±1` / `gz±1` neighbour via `_FindNeighbour` (which also
  peeks `gy±1` to bridge small steps).
- Server `GetCellAt(pos)` just returns the nearest cell in the local 3×3 column.

Persistence:

- **Client → server** streams cells in batches (`Navmesh:StoreBegin/StoreBatch/StoreCommit`).
- **Server schema:** `<map>_navmesh(id, gx, gz, gy, x, y, z)` + `<map>_navmesh_meta(cellSize, cellCount)`.
- **Helper** (`set_navmesh_files` / `set_navmesh_db`) exports/imports `.navmesh` text files:
  ```
  cellSize;<value>
  gx;gz;gy;x;y;z
  <rows...>
  ```

Two facts that constrain everything below:

- **The server cannot raycast.** VU only exposes raycasting on the client — it's the entire
  reason the bake lives client-side. So any geometry-aware connectivity *must* be computed
  on the client at bake time and stored; it can never be derived at query time on the server.
- **There is no runtime consumer yet.** The server stores the mesh and exposes
  `GetCellAt` / `IsWalkable` stubs, but nothing reads it for AI. This makes *now* the
  cheapest possible moment to change the representation.

---

## 3. Problems and why the current model can't fix them

| Problem | Root cause | Fixable in current model? |
| --- | --- | --- |
| Links pass through thin walls | Adjacency is `gx±1` positional; no horizontal traversability test, nothing stored to say "these two are NOT connected" | **No** — there is no edge to remove |
| Can't manually link across a gap (jump/ledge) | Only grid-adjacent cells can ever connect | **No** |
| Can't manually unlink a bad connection | Nothing to toggle; the grid re-derives it next frame | **No** |
| Uniform resolution wastes cells in open areas / lacks detail near geometry | One global `cellSize` baked into the grid keys | **No** |
| Single-cell precision add/remove | Brush works by radius | Partially (a pick tool fits the current model) |

The generic A* in `astar-lib/a-star.lua` also rescans *every* node to find neighbours
(`neighbor_nodes`), i.e. O(N) per expansion. At ~26k cells that's unusable for runtime
pathfinding. Explicit per-node neighbour lists are what make A* tractable — another reason
edges are the linchpin.

---

## 4. Goals / non-goals

**Goals**
- Connectivity that respects geometry (no links through walls), computed at bake.
- Manual editor control: add/remove single cells, link/unlink two cells, author jump links.
- Adaptive resolution: finer where it matters, coarser in open areas.
- Keep the existing brush-based editing workflow; don't regress editor usability.
- Stay within the client-bake / server-store / helper-export pipeline that already works.

**Non-goals**
- Full Recast/Detour polygon meshing (see §5). Out of scope; revisit only if the quadtree
  approach proves insufficient.
- Building the runtime pathfinder itself. This doc only ensures the *representation* feeds
  one cleanly.
- Smooth path string-pulling / funnel. Future, once a runtime consumer exists.

---

## 5. Decision and alternatives

**Chosen direction:** evolve the voxel grid by (Phase 1) making adjacency explicit, then
(Phase 2) allowing quantized variable cell size on top of those explicit edges.

**Alternatives considered:**

- **Status quo (implicit grid).** Rejected: structurally cannot represent "adjacent but not
  connected," and the server can't raycast to fix it at query time.
- **Full Recast/Detour polygon navmesh.** Rejected *for now*: Recast is the canonical answer
  to adaptive density, but it's native C++ (VU is Lua) and needs the level's collision
  triangle mesh as input — which BF3 doesn't expose, the very reason the bake raycasts
  in-game. Reimplementing its later stages (region partition → contour → convex poly mesh
  with adjacency) in Lua is a large, high-risk project, and polygon editing is *harder* than
  cell editing, so it would regress the editor. A quadtree of explicit-edge cells reaches the
  same adaptive-density benefit at a fraction of the cost and risk.

**Key insight:** explicit edges decouple *where cells are* from *what connects to what*.
That decoupling is exactly what (a) fixes the geometry problem, (b) enables manual
link/unlink and jump links, and (c) makes non-uniform cell sizes possible at all.

---

## 6. Phase 1 — Explicit edges

### 6.1 Data model

Each cell gains connectivity data. Two complementary forms:

- **Grid edges** — packed as a small bitmask per cell for the 4 (or 6, incl. up/down for
  steps) axis-aligned neighbours. Cheap, covers the common case, and a cleared bit means
  "wall here, do not connect." Default after bake = set only for neighbours that pass the
  traversability test.
- **Extra edges** — a small side-list for arbitrary cell-to-cell links that aren't grid
  neighbours (jumps across gaps, drop-downs, authored shortcuts). Stored as cell-id pairs.

The overlay and runtime read edges from this data instead of recomputing `gx±1`.

### 6.2 Bake-time edge generation (the geometry fix)

When the flood-fill connects a cell to a neighbour, add a **horizontal traversability
raycast** between the two cell centres at body height (e.g. a low and/or mid sample above
the floor, with a small start offset so the ray doesn't self-hit the origin cell's floor).
If blocked → no edge. This is a localized addition to the neighbour-expansion step and to
the paint tool (which probes the same way). Cost: roughly one extra ray per neighbour
candidate; the bake is already time-throttled, so this slows baking but doesn't break it.

### 6.3 Serialization

- **Client → server stream:** extend each cell record with its grid-edge bitmask; stream
  extra-edges in their own batch phase (same throttled streaming pattern as cells).
- **Server schema:** add `edges INTEGER` (bitmask) to `<map>_navmesh`; add a
  `<map>_navmesh_links(a_id, b_id)` table for extra edges. Bump the meta/version so loaders
  can tell old data apart.
- **Helper `.navmesh` format:** add the bitmask as a 7th column, and an optional `links`
  section after the cell rows. Update `set_navmesh_files` / `set_navmesh_db` accordingly.

### 6.4 Overlay

Draw the real edges (grid bitmask + extra links) instead of `_FindNeighbour`'s implicit
guess. This is simpler and more honest once edges exist; culled links visibly disappear,
which is the inspection feedback the user wants.

### 6.5 Editor tools

- **Single-cell add/remove (pick tool):** toggle the one cell under the cursor. The cursor
  raycast already exists; this is a min-radius/precision variant of paint/erase.
- **Link / unlink tool:** two-click select (click cell A, click cell B) → toggle the edge
  between them. The box tool's existing two-click corner pattern is the template. Unlinking
  a grid pair clears its bitmask bit; linking a non-adjacent pair adds an extra edge.

### 6.6 Backward compatibility

Old saved meshes have no edge data. On load, synthesize grid edges once using the existing
neighbour logic (optionally re-running the traversability ray, since the client *can*
raycast at load). Old `.navmesh` files import as "all grid neighbours connected," then can
be cleaned up in the editor.

---

## 7. Phase 2 — Variable resolution (quadtree)

Enabled by Phase 1: once connectivity is stored as edges, cells no longer have to be uniform.

### 7.1 Quantized, not arbitrary

Sizes are always `baseSize / 2^k`. A cell subdivides into 4 children; 4 siblings merge into
1 parent. This keeps indexing sane (you can still hash against the finest level), makes
subdivide/merge exact and reversible, and avoids the alignment chaos of arbitrary sizes.
This is a "framed quadtree" navmesh — a known, simpler-than-Recast adaptive technique.

### 7.2 Data model changes over Phase 1

- Each cell carries a **size/level** field.
- **Identity stops being the grid key.** Cells become `{ id, x, y, z, size, edges }`, found
  via a **spatial index** (e.g. hash at the finest level, or a quadtree) rather than
  `floor(x / cellSize)`. This is the main new work — the runtime `GetCellAt(point)` must
  resolve the covering cell regardless of size.
- Edges already explicit (Phase 1), so a big cell connecting to several small neighbours is
  just multiple stored edges. No special-casing.

### 7.3 Operations — same machinery, two directions

- **Manual subdivide / merge (the noclip-driven workflow):** subdivide a cell → replace it
  with 4 children, re-probe their floors, rewire edges (validate with traversability rays).
  Merge → collapse 4 siblings into one, rewire. This is the "add resolution here" tool the
  user asked for.
- **Automatic coarsen pass (the optimization knob):** greedily merge contiguous, co-planar,
  fully-connected quads in open areas into bigger cells; keep fine cells adjacent to mesh
  boundaries / height discontinuities (where detail matters). This is "merge applied
  broadly" — same operation pointed at openness instead of a hand-picked spot.

### 7.4 Serialization changes

Add the `size`/level field to the cell record/schema/`.navmesh` format. Spatial index is
rebuilt on load from the cell list, so it isn't serialized directly.

---

## 8. Runtime considerations (future consumer)

- **Pathfinding** runs A* over the explicit edge graph: cells are nodes, stored edges are
  links. This is what makes it tractable — replace the O(N) neighbour scan in
  `astar-lib/a-star.lua` with each node's stored neighbour list. Heuristic = 3D distance
  between cell centres; edge cost = same, optionally weighted (e.g. discourage jump links).
- **Server can't raycast**, so it consumes only what was baked. All geometry awareness is
  frozen into the stored edges at bake/edit time. This is a hard constraint, not a choice.
- **Smoothing** (funnel / string-pulling) is a later concern; variable-size cells make raw
  centre-to-centre paths blockier, so some smoothing will eventually be wanted.

---

## 9. Runtime loading & storage format

### 9.1 What VU actually allows

VEXT has **no general file I/O** — there is no `io`/`loadfile`/filesystem API in the
reference. At runtime, the game can only obtain data from:

- the **SQL DB** (`mod.db`, server-side only),
- **`require()`d Lua modules** bundled in the mod,
- NetEvents (messaging, not bulk storage), or
- Frostbite EBX/partitions (game data, not ours).

Critically, the `.map` / `.navmesh` text files are **not readable by the game** — only the
Python helper reads them. So the only non-DB way to feed runtime data is to **bake it into
a `require()`able Lua module.** (`SharedUtils:SerializeTable(table) → string` exists if a
generator is wanted.)

### 9.2 Correcting the startup-cost model

A common worry is "if all maps' navmeshes lived in the DB, startup would be slow." That's
mostly a misconception:

- The DB load is **per-map**. `NodeCollection` reads only the current map's table
  (`SELECT * FROM <map>_table`), and each map+mode is its own table. SQLite reads only the
  rows for the map being loaded, regardless of how many other maps exist. **Per-map load
  time is proportional to that map's data, not the total.**
- What *does* grow with "all maps" is the **DB file size** — a multi-hundred-MB binary blob
  is bad for git and distribution (`mod.db` is already ~51 MB). That's a *distribution*
  problem, not a load-time one.

### 9.3 Two separable problems, two separate fixes

| Problem | Fix |
| --- | --- |
| Level-load **hitch** on a big mesh | Stream the load across frames, the way `NodeCollection.ProcessAllDataToLoad` already does. Today `Navmesh:Load()` is a single synchronous query + loop — *that's* what stalls, regardless of format. |
| Giant binary **DB** to ship/version for many maps | Move runtime data out of the DB into bundled, git-friendly per-map files. |

These are orthogonal and stack. The adaptive-resolution work (§7) helps both — fewer cells
means less to load and less to ship.

### 9.4 The Lua-module route (solves the distribution problem)

If/when the DB-size problem matters, precompile per-map data to Lua modules:

- **Lazy per-map `require`** — `require('navmesh/' .. mapName)` returns that map's data,
  loaded only when that level loads. Same laziness as the DB's per-map query; other maps
  cost nothing until played.
- **Keep it in `ext/server`**, not `ext/shared`. Server scripts are not shipped to clients,
  so the (large) navmesh data won't bloat client downloads. Navmesh is server-runtime data.
- **Store as one big string constant, not a giant table literal.** A 26k-entry nested-table
  literal in a single chunk can hit Lua's per-function constant/register limits and is slow
  to compile. Embed the compact `gx;gz;gy;x;y;z;edges` rows (the same `.navmesh` layout) as
  a single string and parse it with string ops at load — one constant, no compile-limit
  trap, fast to parse.
- **Add a helper export step** (DB → `ext/server/navmesh/<map>.lua`), exactly analogous to
  today's `.map` export. The editor writes the DB; the helper regenerates the bundled Lua;
  you commit it.

### 9.5 The recommended split

- **DB = authoring + editor streaming.** It's genuinely good at the client↔server save/load
  streaming the editor needs; keep it there.
- **Bundled Lua modules = runtime + distribution.** Loaded once at level load into memory
  (ideally streamed across frames), then **never queried at runtime** — all runtime access
  is in-memory, mirroring how bots already consume `NodeCollection`.

Sequencing note: if the immediate pain is a load hitch, do the **streamed load** first
(small change). The Lua-module format is the follow-on that removes the binary-DB
distribution burden; it is not required to fix a stall.

---

## 10. Risks & open questions

- **Traversability ray tuning** — body-height samples and start offset need tuning to avoid
  false positives (self-hits, doorframes) and false negatives (thin railings). Expose as
  Registry constants and validate by eye in the overlay.
- **Streaming size** — edges add to the save/load payload. Bitmask-in-cell is nearly free;
  the extra-links list and Phase 2 size field add a little. Keep the throttled batching.
- **Spatial index cost (Phase 2)** — multi-level lookup must stay cheap for runtime queries
  at scale. Decide hash-at-finest-level vs. quadtree before building Phase 2.
- **Helper format/version** — bump a version marker in the `.navmesh` header so old files
  import cleanly and the importer can branch.
- **Diagonal movement** — current bake is 4-neighbour only; whether to add diagonal grid
  edges (with corner-cutting checks) is an open question, independent of the above.

---

## 11. Suggested sequencing

1. **Slice 0 (cheap, immediate):** single-cell pick add/remove. Pure editor, fits today's
   model, no schema change.
2. **Slice 1 (the linchpin):** grid-edge bitmask + bake-time traversability culling +
   overlay drawing real edges. Fixes "links through walls." Schema/format/version bump.
3. **Slice 2:** manual link / unlink tool + extra-edges (jump links).
4. **Slice 3:** automatic coarsen pass over the uniform grid (first taste of adaptive
   density, still single base size).
5. **Slice 4 (Phase 2):** quantized variable size — size field, spatial index, manual
   subdivide/merge.

Land Slice 1 solid before Slice 4. Edges first, resolution second.
