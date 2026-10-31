// usage: [MODE=customer] node run-chapter.js <journey.md> <fromChapter> <toChapter|end> <out.sh>   (chapter ids 0–31, B; both inclusive; "A" is accepted as the old name of 0)
// consecutive blocks on the same host/user run in ONE shell, fed from a file (stdin=/dev/null so ssh can't eat it)
// MODE: only `customer` exists now (CyberArk PAM only); the variable is kept so older call sites still work.
// ops02: people arrive as root (PVWA + PSMP in production, plain podman exec in the lab); root's ~/.ssh/config points at /secure/ssh/cpuser_ed25519, so nothing needs to be passed in.
const fs=require("fs"); const [,, md, from, to, out]=process.argv;
const MODE=process.env.MODE||"customer";
if(MODE!=="customer") throw new Error("MODE must be customer (the only mode left)");
const s=fs.readFileSync(md,"utf8");
// chapters are `# <id>. title` outside code fences; ids are 0..31 (0 = build the lab) plus appendix B (monitoring coverage, lab tear-down).
// run order = 0, 1..31, then B. <from>/<to> are chapter ids, both inclusive; <to> may be "end".
const chapters=[]; { let fence=false, cur=null; for(const l of s.split("\n")){ if(/^```/.test(l)) fence=!fence; const m=!fence&&/^# ([0-9]{1,2}|[A-Z])\. /.exec(l); if(m){ cur={id:m[1],lines:[]}; chapters.push(cur); } else if(cur) cur.lines.push(l); } }
const order=[...chapters.filter(c=>/^\d+$/.test(c.id)).sort((x,y)=>+x.id-+y.id),...chapters.filter(c=>/^[A-Z]$/.test(c.id))];
const idx=(id)=>{ if(String(id)==="A") id="0"; const i=order.findIndex(c=>c.id===String(id)); if(i<0) throw new Error("chapter not found "+id); return i; };
const i0=idx(from), i1=(to==="end"||to===undefined)?order.length-1:idx(to);
if(i1<i0) throw new Error(`to (${to}) comes before from (${from}) in the run order ${order.map(c=>c.id).join(" ")}`);
const sec="\n"+order.slice(i0,i1+1).map(c=>`# ${c.id}. \n`+c.lines.join("\n")).join("\n");
const re=/\n((#{1,3}) [^\n]+)|@role ([^\n]+)|```bash\n([\s\S]*?)```/g; let m, role=null, n=0, head="";
const groups=[];
while((m=re.exec(sec))){
  if(m[1]){ head=m[1]; continue; }
  if(m[3]){ const p=m[3].split("|").map(x=>x.trim()); role={who:p[0],host:p[1],user:p[2],note:p[3]||""}; continue; }
  const code=m[4]; n++;
  if(!role) throw new Error(`block ${n} (${head.trim()}) has no @role before it`);
  if(role.host==="—" ||/\s-it\s/.test(code)) { groups.push({key:"skip",blocks:[{n,head,why:"interactive"}]}); continue; }
  // @role 的第四欄寫了「整本實跑不執行」：只在需要時才做的破壞性程序（例如 26.4 清空叢集），已另外在 lab 照原文手動實跑過
  if(/整本實跑不執行/.test(role.note||"")) { groups.push({key:"skip",blocks:[{n,head,why:"on-demand, destructive"}]}); continue; }
  let ex=null, key="local";
  if(!/Windows/.test(role.host)) {
    const c= role.host==="dl01" ? "dl01" : `lab-${role.host}-1`;
    const u= role.host==="ops02" ? "-w /root" : "";
    ex=`podman exec ${u} ${c}`.replace("podman exec  ","podman exec "); key=c+"|"+role.user;
  }
  const g=groups[groups.length-1];
  if(g && g.key===key) g.blocks.push({n,head,code,host:role.host,user:role.user}); else groups.push({key,ex,blocks:[{n,head,code,host:role.host,user:role.user}]});
}
let o=`set +e\nexport MSYS_NO_PATHCONV=1\ncd ~\necho "===== MODE ${MODE} ====="\n`;
let run=0, skipped=0;
for(const g of groups){
  if(g.key==="skip"){ for(const bl of g.blocks){ skipped++; o+=`\necho "===== BLOCK ${bl.n} ${bl.head} skipped (${bl.why}) ====="\n`; } continue; }
  let body="";
  for(const bl of g.blocks){
    run++;
    body+=`echo "===== BLOCK ${bl.n} [${bl.host} ${bl.user}] ${bl.head} ====="\n${bl.code}rc=$?; echo "===== rc=$rc ====="; [ $rc -ne 0 ] && { echo "STOP at block ${bl.n}"; exit 1; }\n`;
  }
  if(g.ex) o+=`\n${g.ex.replace("podman exec","podman exec -i")} bash -c 'cat > /tmp/runner.sh' <<'__BLK__'\n${body}exit 0
__BLK__\n${g.ex} bash /tmp/runner.sh </dev/null\n[ $? -ne 0 ] && exit 1\n`;
  else o+=`\n${body}`;
}
o+="\nexit 0\n";
fs.writeFileSync(out,o); console.log(`mode: ${MODE} blocks: ${n} run: ${run} skipped: ${skipped}`);
