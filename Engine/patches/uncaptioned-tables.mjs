import fs from 'node:fs';
import path from 'node:path';

// Native distribution patch over pinned upstream assets. Inkwell's two-column
// bridges wait for a caption's tabularnewline before opening the tabular. Pandoc
// emits a top rule first for uncaptioned tables, so also recognize that boundary.
// Keep Vendor/Inkwell unchanged so the source pin and patch remain inspectable.
export function patchUncaptionedTables(runtime) {
  for (const [id, prefix] of [['rho','rho'],['rmxaa','rmxaa']]) {
    const file=path.join(runtime,'templates',id,id+'.latex');
    let text=fs.readFileSync(file,'utf8');
    const original=String.raw`  \let\PREFIX@origtabularnewline\tabularnewline
  \def\tabularnewline{%
    \let\tabularnewline\PREFIX@origtabularnewline
    \expandafter\tabular\expandafter{\PREFIX@colspec}%
  }%`.replaceAll('PREFIX',prefix);
    const replacement=String.raw`  % Pandanote: captioned and uncaptioned Pandoc table entry points.
  \let\PREFIX@origtabularnewline\tabularnewline
  \let\PREFIX@originaltoprule\toprule
  \def\PREFIX@starttabular{%
    \let\tabularnewline\PREFIX@origtabularnewline
    \let\toprule\PREFIX@originaltoprule
    \expandafter\tabular\expandafter{\PREFIX@colspec}%
  }%
  \def\tabularnewline{\PREFIX@starttabular}%
  \def\toprule{\PREFIX@starttabular\toprule}%`.replaceAll('PREFIX',prefix);
    if (!text.includes(original)) throw new Error(`The ${id} table bridge changed; review the native compatibility patch.`);
    text=text.replace(original,replacement);
    if (id === 'rmxaa') text=text.replace(String.raw`\setbool{rho-abstract}{true}`,String.raw`\setbool{rho-abstract}{$if(abstract)$true$else$false$endif$}`);
    fs.writeFileSync(file,text);
  }
}
