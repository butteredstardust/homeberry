# assets

Project artwork. Only one of these is read at runtime — `homeberry-256.png`, which `provision.sh`
copies into `appdata/starbase80/icons/` to serve as the dashboard logo. The rest exist so the README
has a mark and so the icon can be redrawn without going back to the design tool.

| File                      | What it is                                                                     |
| ------------------------- | ------------------------------------------------------------------------------ |
| `homeberry.png`           | 1024×1024 composed icon. This is the one the README embeds.                     |
| `homeberry-256.png`       | The same icon at dashboard size. Installed as `/icons/homeberry.png` on the Pi. |
| `homeberry.svg`           | Vector source of the composed icon, rounded backplate included.                 |
| `homeberry-freeform.svg`  | The berry alone, no backplate — for anywhere a square tile would be wrong.      |

The mark is a raspberry assembled out of stacked isometric blocks: thirteen containers on one small
board, which is what `docker-compose.yml` describes.

Sizing is deliberate. The dashboard logo renders at well under 100px, so a 1024×1024 PNG would cost
~50 KB on every page load and in every nightly appdata backup, for pixels nobody sees.
