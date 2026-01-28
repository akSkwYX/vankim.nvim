;; Inject typst/latex parsers into the inner content node range.

((typst_block
   content: (typst) @injection.content)
 (#set! injection.language "typst"))

((latex_block
   content: (latex) @injection.content)
 (#set! injection.language "latex"))
