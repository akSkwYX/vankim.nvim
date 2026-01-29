module.exports = grammar({
   name: 'anki',

   extras: $ => [/\s/],

   rules: {
      source_file: $ => repeat(choice($.header, $.field)),

      header: $ => seq(
         field('key', token(choice('Model', 'Deck'))),
         ':',
         field('value', /.*/)
      ),

      field: $ => seq(
         field('name', /[^:\n]+/),
         ':',
         field('body', repeat(choice(
            $.typst_block, 
            $.latex_block, 
            $.text
         )))
      ),

      typst_block: $ => seq(
         '[typst]',
         field('content', alias($._block_content, $.typst)),
         '[/typst]'
      ),

      latex_block: $ => seq(
         '[latex]',
         field('content', alias($._block_content, $.latex)),
         '[/latex]'
      ),

      _block_content: $ => prec(-1, repeat1(choice(/./, /\n/))),

      text: $ => /[^\[\n]+/
   }
});
