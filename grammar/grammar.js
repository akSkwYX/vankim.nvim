module.exports = grammar({
   name: 'anki',

   extras: $ => [],

   rules: {
      source_file: $ => repeat(choice($.header, $.field, $.blank_line)),

      blank_line: $ => token(/\s*\n/),

      header: $ => seq(
         field('key', token(choice(/Model/, /Deck/))),
         ':',
         field('value', token(/.*\n/))
      ),

      field: $ => seq(
         field('name', token(/[^\n:]+/)),
         ':',
         optional(field('body', repeat(choice($.typst_block, $.latex_block, $.text_line, $.blank_line))))
      ),

      text_line: $ => token(/(?:[^\[\n]|\[(?!\/?(typst|latex)\]))+\n?/),

      typst_block: $ => seq(
         token('[typst]'),
         field('content', token(/[\s\S]*?(?=\[\/typst\])/)),
         token('[/typst]')
      ),

      latex_block: $ => seq(
         token('[latex]'),
         field('content', token(/[\s\S]*?(?=\[\/latex\])/)),
         token('[/latex]')
      ),
   }
});
