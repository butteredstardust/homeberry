# assets

These files are project artwork. At runtime, `provision.sh` copies only
`homeberry-256.png` to `appdata/starbase80/icons/` for the dashboard logo. Use
the remaining files for the README or to redraw the icon.

| File                      | What it is                                                                     |
| ------------------------- | ------------------------------------------------------------------------------ |
| `homeberry.png`           | 1024×1024 composed icon. This is the one the README embeds.                     |
| `homeberry-256.png`       | The same icon at dashboard size. Installed as `/icons/homeberry.png` on the Pi. |
| `homeberry.svg`           | Vector source of the composed icon, rounded backplate included.                 |
| `homeberry-freeform.svg`  | The berry alone, no backplate — for anywhere a square tile would be wrong.      |

The mark is a raspberry made from stacked isometric blocks. It represents the
thirteen containers on one small board in `docker-compose.yml`.

Use `homeberry-256.png` for the dashboard. The dashboard renders the logo below
100px. A 1024×1024 PNG adds ~50 KB to every page load and nightly appdata backup.
