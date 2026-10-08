# Executor icons

Verified on 2026-10-07. These assets identify the corresponding executors; each mark remains the property of its vendor.

| Local asset | Mark and primary source | Original asset |
| --- | --- | --- |
| `codex.svg` | OpenAI Blossom, extracted from the official [Codex documentation](https://developers.openai.com/codex/). See also [OpenAI design guidelines](https://openai.com/brand/). | Inline 24 × 24 OpenAI mark in the documentation header. A dedicated downloadable Codex product SVG was not located in this check; this is the verified OpenAI mark used on the Codex documentation site. |
| `claude.svg` | Claude Spark from the official [Anthropic press kit](https://anthropic.com/press-kit), linked by the [Anthropic newsroom](https://www.anthropic.com/news). | `Anthropic media resources/Anthropic logos/Claude logos/3 Claude Spark/SVG/Claude Spark - Clay.svg` |
| `claude-clay.svg` | Same official Claude Spark, retaining the provided clay fill (`#D97757`). | Same source path as above. |
| `cursor.svg` | Cursor 2D cube from the official [Cursor brand guidelines](https://cursor.com/brand). | `General Logos/Cube/SVG/CUBE_2D_LIGHT.svg` in the linked brand asset archive. |

Official archive endpoints resolved during verification:

- [Anthropic press kit archive](https://www-cdn.anthropic.com/ae59ca4ca194dac9c9dc3bc78c5829468cb0e8af.zip)
- [Cursor brand asset archive](https://ptht05hbb1ssoooe.public.blob.vercel-storage.com/assets/brand/cursor-brand-assets.zip)

The three standard SVGs use `currentColor` for small UI presentation in light and dark appearances. Claude's companion SVG retains the source brand color. All original path coordinates and view boxes are preserved; document classes, unused wrappers and generator metadata were removed. Each asset contains one editable vector path, no raster image, script or external reference. Scale with preserved aspect ratio into a 16–20 px slot and keep the executor name adjacent.

The SVGs are suitable for inline symbols in the standalone HTML prototype and editable vector import in Figma. An external `<img>` does not inherit surrounding `currentColor`; use an inline SVG or a CSS mask for adaptive monochrome presentation.
