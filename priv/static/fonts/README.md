# IBM Plex

Self-hosted WOFF2 fonts from [IBM/plex](https://github.com/IBM/plex), under the
[SIL Open Font License](OFL.txt). These are the complete Sans and Mono faces
from `packages/plex-{sans,mono}/fonts/complete/woff2/`, retrieved September 9, 2026.
The filenames identify the normal and italic 400/500 weights, plus Sans 600.

`assets/css/app.css` declares the faces. The browser tests load every face and
check same-origin delivery so production CSP does not need a font CDN exception.
