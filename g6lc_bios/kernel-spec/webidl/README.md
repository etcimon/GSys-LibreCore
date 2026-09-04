# WebIDL — spec of record for the BIOS browser

Mozilla WebIDL under `definitions/` (MPL-2.0). Rewrite, do not compile.

Live vs stub is decided by `g6b-webidl` against this catalog: DOM/HTML/Canvas
interfaces needed to paint the BIOS UI and a GL viewport are **live**; Fetch,
Crypto, WebGL, XHR, CSSOM are **stubs** until a later pass. Chrome-only and
media/WebRTC interfaces are **refused**.

See `architecture/BROWSER.md` and `architecture/DISPLAY.md`.
