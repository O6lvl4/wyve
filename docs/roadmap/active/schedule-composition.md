<!-- description: k-tiling, tile x interchange composition, tune sweeping schedules -->
# Schedule composition

- 3D tiles (`@tile(i: _, j: _, p: _)` with the reduction axis under
  `@fp(reassoc)` legality) so the b-tile fits L2 — the headroom @tile
  v1 left on the table (bench/NOTES.md).
- `@tile` × `@interchange` composing on one kernel (currently WVN022
  forbids the combination; the right order is interchange first, then
  tile the new nest).
- `tune` sweeping schedules the way it sweeps widths: tile sizes ×
  interchange on/off × fp grants, with remark verification per variant.
