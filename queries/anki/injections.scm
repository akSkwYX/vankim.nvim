;; Inject typst/latex parsers into the inner content node range.

(
  (typst_block (content) @typst_content)
  (#set! injection.language "typst")
)

(
  (latex_block (content) @latex_content)
  (#set! injection.language "latex")
)
