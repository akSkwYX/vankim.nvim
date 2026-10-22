if exists("b:current_syntax") | finish | endif

syn match ankiHeader /^\(Model\|Deck\):/
hi def link ankiHeader Keyword
hi def link ankiField Title

lua require("vankim.syntax").define_fields()

unlet! b:current_syntax
syn include @ankiTex syntax/tex.vim
unlet! b:current_syntax
syn include @ankiTypst syntax/typst.vim
unlet! b:current_syntax

syn region ankiLatex matchgroup=Delimiter start=/\[latex\]/ end=/\[\/latex\]/ contains=@ankiTex keepend
syn region ankiTypst matchgroup=Delimiter start=/\[typst\]/ end=/\[typst\]/ contains=@ankiTypst keepend

let b:current_syntax = "vankim"
