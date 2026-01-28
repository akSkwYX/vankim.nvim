;; Basic highlighting: tag Bracket and header/field names
(header key: (key_name) @keyword)
(header value: (value_content) @string)

(field name: (field_name) @label)

(typst_block typst_open_tag: (typst_open_tag) @punctuation.delimiter)
(typst_block typst_close_tag: (typst_close_tag) @punctuation.delimiter)
(latex_block latex_open_tag: (latex_open_tag) @punctuation.delimiter)
(latex_block latex_close_tag: (latex_close_tag) @punctuation.delimiter)

(text) @text
