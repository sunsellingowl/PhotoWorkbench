# Third-party components

PhotoWorkbench uses the [ImageOptim](https://imageoptim.com/) backend by **Kornel Lesiński and contributors**, from [ImageOptim/ImageOptim](https://github.com/ImageOptim/ImageOptim) at commit `8a4651e14ca53022f6a318071d08bb132fc56ce9`, with the reviewable modifications in `patches/imageoptim.patch`. The Swift UI, rename workflow, candidate validation and transactional save adapter are additions in `native/`. The original third-party copyright notices are retained. This is an independent project, not an official ImageOptim release or an endorsement by its authors. Copyright in third-party code and engines remains with their respective rights holders.

Engine executables were copied from the locally installed ImageOptim 1.9.3, except PNGOUT, obtained from its official macOS download. A source commit and an application release are separate provenance records; this project does not assert that the bundled binaries were compiled from that exact ImageOptim source commit. Engine SHA-256 values identify the exact inputs in `dependencies.lock.json`; no unreported version is guessed.

PhotoWorkbench's original contributions are licensed under GPL-2.0-or-later; see `LICENSE` and `COPYRIGHT`. This grant does not change the licenses of third-party code or engines listed below.

| Component | Version / identity | License / notice |
| --- | --- | --- |
| ImageOptim backend | Commit above | GPL v2 or later, `ImageOptim-LICENSE.txt` |
| OxiPNG | 9.0.0 | MIT, `OxiPNG-LICENSE.txt` |
| pngquant / libimagequant | pngquant 3.0.2 | GPL v3 or later and original pngquant licenses, `pngquant-COPYRIGHT.txt` |
| JPEGOptim | 1.4.4 | GPL v2 or later, `JPEGOptim-COPYING.txt` |
| Jpegtran / MozJPEG and companion JPEG library | CLI reports MozJPEG 4.1.5, build 20231014 | IJG, BSD and zlib-style components, `MozJPEG-LICENSE.txt`, `MozJPEG-IJG.txt` |
| PNGCrush and companion libpng | 1.8.10, modified for ImageOptim; libpng 1.4.5-optipng | PNGCrush permission notice extracted from this exact executable's `-h` output, `PNGCrush-LICENSE.txt` |
| AdvPNG / AdvanceCOMP | 1.15 | GPL v2 or later, release-specific `AdvanceCOMP-COPYING.txt` |
| Guetzli | ImageOptim 1.9.3 bundle, identified by SHA-256 | Apache 2.0, `Guetzli-LICENSE.txt` |
| ZopfliPNG | ImageOptim 1.9.3 bundle, identified by SHA-256 | Apache 2.0, `Zopfli-COPYING.txt` |
| PNGOUT | Official 2023-03-22 macOS universal build | Closed source; separate official distribution, `PNGOUT.txt` |
| libpng validator | 1.6.50, compiled into PhotoWorkbench | libpng license, `libpng-LICENSE.txt` |
| System frameworks / zlib / SQLite | macOS SDK and runtime | Supplied by macOS; not copied into the application |

Upstream license texts are retained in `licenses/` and copied into the app. ImageOptim's bundled credits and PNGOUT's readme are copied during preparation. Source URLs and checksum values for the downloaded notices are in the lock file. The public repository contains source and build inputs, not third-party engine binaries or application release assets.

PNGOUT is closed source and is not covered by the GPL. ImageOptim's credits state that its own PNGOUT bundle is included with permission of Ardfry Imaging, LLC; that statement is not permission for PhotoWorkbench to redistribute it. PNGOUT's readme identifies Ken Silverman and Jonathon Fowler but does not establish an independent redistribution grant here. Before publishing a bundled application, verify redistribution permission for every engine and provide the corresponding source and build materials required for GPL components. A version lock or a link to a binary download alone is not a substitute for those obligations.

## Local deviations from ImageOptim

- A different application bundle, own settings domain, internal engine paths, and no migration of original ImageOptim preferences or caches.
- Strict lossless mode suppresses transparent RGB-changing flags. Lossy opt-in retains those upstream flags.
- Zopfli's preservation list includes `eXIf`; all candidates are additionally checked before acceptance.
- Guetzli requires explicit lossy settings. A settings change invalidates in-session worker skip records.
- `PWJob` overrides saving and restoration with verified, same-volume atomic replacement and rollback, while retaining the smaller-result selection and Trash-based original retention.
- Cancellation/temporary file handling and engine error reporting are hardened. Two images are admitted at once; upstream worker scheduling handles their engines.
- No persistent results cache is enabled in this version. Its source is retained for compatibility, with legacy cache migration removed.

The upstream comparison harness used for the initial 0.9 validation is preserved in the `v0.9` Git tag. It uses pristine source from the locked archive, adapting only the UI header import and bundled executable locator. The current source tree keeps the native file-safety regression checks and omits that initial comparison harness.
