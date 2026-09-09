/* A small syntax highlighter for D. No dependencies, ~60 lines: this site
   ships no third party code, just like serverino ships no dependencies. */

(function (global) {
   const KEYWORDS = new Set(("abstract alias align asm assert auto body break case cast catch class " +
      "const continue debug default delegate delete deprecated do else enum export extern false final " +
      "finally for foreach foreach_reverse function goto if immutable import in inout interface invariant " +
      "is lazy mixin module new nothrow null out override package pragma private protected public pure " +
      "ref return scope shared static struct super switch synchronized template this throw true try " +
      "typeid typeof union unittest version void while with __gshared __traits").split(" "));

   const TYPES = new Set(("bool byte ubyte short ushort int uint long ulong float double real char wchar " +
      "dchar string size_t Request Output WebSocket WebSocketMessage ServerinoConfig Cookie Duration " +
      "SysTime JSONValue Fallthrough Https Daemon").split(" "));

   const escape = s => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

   /* One pass, longest match first: comments, strings, UDAs, numbers, words. */
   const RE = new RegExp([
      /\/\*[\s\S]*?\*\//.source,          // /* block */
      /\/\+[\s\S]*?\+\//.source,          // /+ nesting block +/
      /\/\/[^\n]*/.source,                // // line
      /r"(?:[^"])*"/.source,              // r"wysiwyg"
      /`(?:[^`])*`/.source,               // `wysiwyg`
      /"(?:\\.|[^"\\])*"/.source,         // "string"
      /'(?:\\.|[^'\\])*'/.source,         // 'c'
      /@[A-Za-z_]\w*/.source,             // @uda
      /\b\d[\d_]*(?:\.\d[\d_]*)?[a-zA-Z_]*\b/.source,
      /\b[A-Za-z_]\w*\b/.source
   ].join("|"), "g");

   function highlight(code) {
      let out = "", last = 0, m;

      RE.lastIndex = 0;

      while ((m = RE.exec(code)) !== null) {
         const tok = m[0];
         let cls = null;

         if (tok.startsWith("//") || tok.startsWith("/*") || tok.startsWith("/+")) cls = "tok-com";
         else if (/^[r`'"]/.test(tok)) cls = "tok-str";
         else if (tok[0] === "@") cls = "tok-uda";
         else if (/^\d/.test(tok)) cls = "tok-num";
         else if (KEYWORDS.has(tok)) cls = "tok-key";
         else if (TYPES.has(tok)) cls = "tok-type";

         out += escape(code.slice(last, m.index));
         out += cls ? '<span class="' + cls + '">' + escape(tok) + "</span>" : escape(tok);
         last = m.index + tok.length;
      }

      return out + escape(code.slice(last));
   }

   global.dhighlight = highlight;
})(window);
