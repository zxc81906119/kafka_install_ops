#!/usr/bin/env node
// 檢查手冊與腳本的指令是否符合 COMMAND-STYLE.md。
//
// 用法（在 repo 根目錄）：
//   node docs/journey-src/tools/lint-commands.js                  檢查全部，列出每一筆
//   node docs/journey-src/tools/lint-commands.js --summary        只列各規則與各來源的筆數
//   node docs/journey-src/tools/lint-commands.js journey.md 21    只檢查手冊第 21 章
//   node docs/journey-src/tools/lint-commands.js install/steps/21-cert-rotate.sh
// 結束碼：0 沒有違規；1 有違規
const fs = require('fs');
const path = require('path');

const MAX_LINE = 120;
const MAX_BLOCK = 60;

// 把單引號字串拿掉，避免 awk、sed 程式內容被當成 shell 語法
function withoutQuoted(line) {
  return line.replace(/'[^']*'/g, "''");
}

// 這一行是否有 lint-ok 註解（同一行或上一行）
function isExempt(lines, i) {
  if (lines[i].includes('lint-ok:')) {
    return true;
  }

  return i > 0 && /^\s*#.*lint-ok:/.test(lines[i - 1]);
}

// 檢查一行 shell 指令，回傳違規規則名稱的清單
function checkShellLine(line) {
  const found = [];
  const bare = withoutQuoted(line);

  if (/^\s*#/.test(line)) {
    return found;
  }

  if (/^\s*if\b.*;\s*then\b.*\S/.test(bare) && !/;\s*then\s*(#.*)?$/.test(bare)) {
    found.push('單行 if');
  }

  if (/^\s*(for|while)\b.*;\s*do\b.*\S/.test(bare) && !/;\s*do\s*(#.*)?$/.test(bare)) {
    found.push('單行迴圈');
  }

  // if／while 條件裡的 [ ] && [ ] 可以；其他都算串接
  const isCondition = /^\s*(if|elif|while)\b/.test(bare);

  if (!isCondition && /(&&|\|\|)/.test(bare.replace(/\$\(\([^)]*\)\)/g, '').replace(/\[\[.*?\]\]/g, ''))) {
    found.push('&&、|| 串接');
  }

  // 算術 $(( )) 裡的 $(date) 可以
  const noArithmetic = bare.replace(/\$\(\(.*?\)\)/g, '');

  if (/\$\([^()]*\$\(/.test(noArithmetic)) {
    found.push('巢狀 $( $( ) )');
  }

  if (line.length > MAX_LINE) {
    found.push('一行超過 ' + MAX_LINE + ' 字');
  }

  if (bare.replace(/\|\|/g, '').split('|').length - 1 >= 3) {
    found.push('管線超過 3 段');
  }

  if (/\bjq\b/.test(bare)) {
    found.push('用了 jq');
  }

  if (/\bsed\b.*\\\(/.test(line)) {
    found.push('sed 帶群組');
  }

  // 複雜 awk：有大括號且不只是 print 欄位
  const awk = line.match(/\bawk\b[^']*'([^']*)'/);

  if (awk && !/^\s*(NR==\d+\s*|\/[^/]*\/\s*)?\{\s*print \$\w+\s*\}\s*$/.test(awk[1]) && !/\{c\+\+\} END \{print c \+ 0\}/.test(awk[1])) {
    found.push('複雜 awk');
  }

  return found;
}

// heredoc 寫到的檔案是不是腳本（內容要照 shell 規則檢查，只有函式可以留）
function writesScript(line) {
  return /\.sh\b[^<]*<</.test(line);
}

// 一個 heredoc 是不是把內容寫到檔案（設定檔或交付的腳本）
function writesFile(line) {
  return /(>\s*\S+|\btee\b).*<<-?\s*['"]?\w+/.test(line) || /<<-?\s*['"]?\w+['"]?\s*(>|\|\s*(sudo\s+)?tee)/.test(line);
}

function heredocWord(line) {
  const m = withoutQuoted(line).length >= 0 && line.match(/<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?/);
  return m ? m[1] : null;
}

// 檢查手冊：回傳 [{ where, line, rule, text }]
function lintJourney(file, onlyChapter) {
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  const problems = [];
  let chapter = '前言';
  let fence = null;
  let heredoc = null;
  let toFile = false;
  let toScript = false;
  let blockStart = 0;
  let blockLines = 0;
  let blockHasFile = false;

  lines.forEach((line, i) => {
    if (fence === null) {
      const m = line.match(/^# ([0-9]{1,2}|[A-Z])\. /);

      if (m) {
        chapter = m[1];
      }

      if (line.startsWith('```')) {
        fence = line.slice(3).trim();
        heredoc = null;
        blockStart = i + 1;
        blockLines = 0;
        blockHasFile = false;
      }

      return;
    }

    if (line.startsWith('```')) {
      if (line.slice(3).trim() !== '') {
        problems.push({ chapter, line: i + 1, rule: '區塊沒關', text: line });
      }

      if (fence === 'bash' && blockLines > MAX_BLOCK && !blockHasFile && (!onlyChapter || chapter === onlyChapter)) {
        problems.push({ chapter, line: blockStart, rule: '一塊超過 ' + MAX_BLOCK + ' 行', text: blockLines + ' 行' });
      }

      fence = null;
      return;
    }

    if (fence !== 'bash') {
      return;
    }

    blockLines++;

    if (heredoc) {
      if (line.trim() === heredoc) {
        heredoc = null;
      } else if (!toFile && !(onlyChapter && chapter !== onlyChapter)) {
        // 送到遠端執行的 heredoc 仍然是人要看的指令
        report(line, i);
      } else if (toScript && !(onlyChapter && chapter !== onlyChapter) && !isExempt(lines, i)) {
        // 手冊寫到磁碟的腳本：可以有函式，其他規則一樣
        for (const rule of checkShellLine(line)) {
          problems.push({ chapter, line: i + 1, rule, text: line.trim().slice(0, 110) });
        }
      }

      // 遠端段落裡又把內容寫到檔案（例如 sudo tee 設定檔）：這一塊不限行數
      if (writesFile(line)) {
        blockHasFile = true;
      }

      return;
    }

    if (!onlyChapter || chapter === onlyChapter) {
      report(line, i);
    }

    const word = heredocWord(line);

    if (word) {
      heredoc = word;
      toFile = writesFile(line);
      toScript = writesScript(line);

      if (toFile) {
        blockHasFile = true;
      }
    }
  });

  function report(line, i) {
    if (isExempt(lines, i)) {
      return;
    }

    for (const rule of checkShellLine(line)) {
      problems.push({ chapter, line: i + 1, rule, text: line.trim().slice(0, 110) });
    }

    if (/^\s*(function\s+)?[a-zA-Z_][a-zA-Z0-9_]*\s*\(\)\s*\{/.test(line)) {
      problems.push({ chapter, line: i + 1, rule: '手冊的指令定義函式', text: line.trim().slice(0, 110) });
    }
  }

  return problems;
}

// 分組的兩條規則（2026-11-13 定案）：目前只套用在 cbom/ 底下的腳本；install、opmenu、手冊還沒照這兩條排過
function usesGroupRules(file) {
  return /(^|[\\/])cbom[\\/]/.test(file);
}

// 把單引號與雙引號字串都拿掉（判斷 ; 是不是在字串裡用）
function withoutStrings(line) {
  return withoutQuoted(line).replace(/"[^"]*"/g, '""');
}

// 這一行是不是用 ; 把兩個指令放在同一行
//   不算的：case 的 ;;、「; then」「; do」、算術 (( ; ; ))、註解裡的 ;
//   例：「name() { echo x; }」算；「for h in $hosts; do」不算
function hasTwoCommands(line) {
  let bare = withoutStrings(line);
  bare = bare.replace(/#.*$/, '').replace(/;;/g, '').replace(/;\s*(then|do)\b/g, '').replace(/\(\(.*?\)\)/g, '');

  return /;\s*\S/.test(bare);
}

// 這一行是不是一個區塊的結束（fi、done、esac、函式的 }），而下一行緊接著別的指令（中間沒有空行）
//   下一行是另一個結束、else、elif、;;、）或檔案結尾時不算；「done < 檔案」「done | 指令」這種也不算（區塊還沒寫完）
function missingBlankAfterEnd(lines, i) {
  const bare = withoutStrings(lines[i]);
  const isEnd = /^\s*(fi|done|esac)\s*(#.*)?$/.test(bare) || /^\s*\}\s*(#.*)?$/.test(bare);

  if (!isEnd) {
    return false;
  }

  const next = lines[i + 1];

  if (next === undefined || next.trim() === '') {
    return false;
  }

  return !/^\s*(fi|done|esac|\}|else|elif|;;|then|\))/.test(next);
}

// 檢查腳本：heredoc 寫到檔案的內容跳過
function lintScript(file) {
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  const problems = [];
  let heredoc = null;
  let toFile = false;
  let toScript = false;

  lines.forEach((line, i) => {
    if (heredoc) {
      if (line.trim() === heredoc) {
        heredoc = null;
      } else if ((!toFile || toScript) && !isExempt(lines, i)) {
        for (const rule of checkShellLine(line)) {
          problems.push({ file, line: i + 1, rule, text: line.trim().slice(0, 110) });
        }
      }

      return;
    }

    if (!isExempt(lines, i)) {
      for (const rule of checkShellLine(line)) {
        problems.push({ file, line: i + 1, rule, text: line.trim().slice(0, 110) });
      }

      if (usesGroupRules(file) && !/^\s*#/.test(line)) {
        if (hasTwoCommands(line)) {
          problems.push({ file, line: i + 1, rule: '一行兩個指令', text: line.trim().slice(0, 110) });
        }

        if (missingBlankAfterEnd(lines, i)) {
          problems.push({ file, line: i + 1, rule: '結束後沒有空一行', text: line.trim() + ' ↵ ' + lines[i + 1].trim().slice(0, 80) });
        }
      }
    }

    const word = heredocWord(line);

    if (word) {
      heredoc = word;
      toFile = writesFile(line);
      toScript = writesScript(line);
    }
  });

  return problems;
}

function shellFiles(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);

    if (e.isDirectory()) {
      shellFiles(p, out);
    } else if (e.name.endsWith('.sh')) {
      out.push(p);
    }
  }

  return out;
}

const args = process.argv.slice(2);
const summary = args.includes('--summary');
const rest = args.filter((a) => a !== '--summary');
const JOURNEY = 'docs/journey-src/journey.md';
let problems = [];

if (rest.length === 0) {
  problems = lintJourney(JOURNEY).map((p) => ({ ...p, source: 'journey' }));

  for (const root of ['install', 'opmenu']) {
    for (const f of shellFiles(root)) {
      problems.push(...lintScript(f).map((p) => ({ ...p, source: root })));
    }
  }
} else if (rest[0].endsWith('.md')) {
  const mdFile = fs.existsSync(rest[0]) ? rest[0] : JOURNEY;
  problems = lintJourney(mdFile, rest[1]).map((p) => ({ ...p, source: 'journey' }));
} else {
  for (const f of rest) {
    problems.push(...lintScript(f).map((p) => ({ ...p, source: f })));
  }
}

if (summary) {
  const table = {};
  const chapters = {};

  for (const p of problems) {
    table[p.source] = table[p.source] || {};
    table[p.source][p.rule] = (table[p.source][p.rule] || 0) + 1;

    if (p.source === 'journey') {
      chapters[p.chapter] = (chapters[p.chapter] || 0) + 1;
    }
  }

  console.log(table);
  console.log('手冊各章：', chapters);
} else {
  for (const p of problems) {
    const where = p.source === 'journey' ? '第' + p.chapter + '章 L' + p.line : p.file + ':' + p.line;
    console.log(where + ' [' + p.rule + '] ' + p.text);
  }
}

console.log('違規 ' + problems.length + ' 筆');
process.exit(problems.length > 0 ? 1 : 0);
