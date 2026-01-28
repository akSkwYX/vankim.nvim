module.exports = grammar({
   name: 'anki',

   extras: $ => [/\s/],

   rules: {
      source_file: $ => seq(
         $.header,
         $.header,
         repeat($.field)
      ),

      header: $ => seq(
         field('key', alias(token(choice('Model', 'Deck')), $.key_name)),
         ':',
         field('value', alias(/[^\n]*/, $.value_content))
      ),

      field: $ => seq(
         field('name', alias(token(/[^:\n]+:\n/), $.field_name)),
         field('body', repeat(choice(
            $.typst_block, 
            $.latex_block, 
            $.text
         )))
      ),

      typst_block: $ => seq(
         field('typst_open_tag', alias('[typst]', $.typst_open_tag)),
         field('content', alias($._block_content, $.typst)),
         field('typst_close_tag', alias('[/typst]', $.typst_close_tag))
      ),

      latex_block: $ => seq(
         field('latex_open_tag', alias('[latex]', $.latex_open_tag)),
         field('content', alias($._block_content, $.latex)),
         field('latex_close_tag', alias('[/latex]', $.latex_close_tag))
      ),

      _block_content: $ => prec(-1, repeat1(choice(/./, /\n/))),

      text: $ => /[^\[\n]+/
   }
});
