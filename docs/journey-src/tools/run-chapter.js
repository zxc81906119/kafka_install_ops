// usage: [MODE=customer|conjur|provider] node run-chapter.js <journey.md> <fromChapter> <toChapterExclusive> <out.sh>
// consecutive blocks on the same host/user run in ONE shell, fed from a file (stdin=/dev/null so ssh can't eat it)
// MODE picks the blocks: an `@only a,b` line limits the section it sits in (right after a heading: that heading's section
// and its subsections; `@only all` ends it) to those modes. Default MODE=customer (the manual's main line).
// On ops02 as cpadmin the engineer's ssh-agent socket is passed in: in customer mode cpadmin's private key exists only there.
const fs=require("fs"); const [,, md, from, to, out]=process.argv;
const MODE=process.env.MODE||"customer";
if(!["customer","conjur","provider"].includes(MODE)) throw new Error("MODE must be customer|conjur|provider");
const AGENT_SOCKET="/home/cpadmin/.ssh/engineer-agent.sock";
const s=fs.readFileSync(md,"utf8");
const a=s.indexOf(`\n# ${from}. `); let b=s.indexOf(`\n# ${to}. `); if(b<0) b=s.length;
if(a<0) throw new Error("chapter not found "+from);
const sec=s.slice(a,b);
const re=/\n((#{1,3}) [^\n]+)|@role ([^\n]+)|@only ([^\n]+)|```bash\n([\s\S]*?)```/g; let m, role=null, n=0, head="";
let level=0; const scopes=[];                // @only 的範圍堆疊：{level, list}；內層要同時符合外層
const groups=[];
while((m=re.exec(sec))){
  if(m[1]){ head=m[1]; level=m[2].length; while(scopes.length && scopes[scopes.length-1].level>=level) scopes.pop(); continue; }
  if(m[3]){ const p=m[3].split("|").map(x=>x.trim()); role={who:p[0],host:p[1],user:p[2]}; continue; }
  if(m[4]){ const list=m[4].trim(); if(scopes.length && scopes[scopes.length-1].level===level) scopes.pop(); if(list!=="all") scopes.push({level, list:list.split(",").map(x=>x.trim())}); continue; }
  const code=m[5]; n++;
  const out_of_mode=scopes.find(x=>!x.list.includes(MODE));
  if(out_of_mode) { groups.push({key:"skip",blocks:[{n,head,why:`only ${out_of_mode.list.join(",")}`}]}); continue; }
  if(!role || role.host==="—" || /\s-it\s/.test(code)) { groups.push({key:"skip",blocks:[{n,head,why:"interactive"}]}); continue; }
  let ex=null, key="local";
  if(!/Windows/.test(role.host)) {
    const c= role.host==="dl01" ? "dl01" : `lab-${role.host}-1`;
    const u= role.user==="cpadmin" ? "-u cpadmin -w /home/cpadmin" : "";
    const agent= role.host==="ops02" && role.user==="cpadmin" ? ` -e SSH_AUTH_SOCK=${AGENT_SOCKET}` : "";
    ex=`docker exec ${u}${agent} ${c}`; key=c+"|"+role.user;
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
  if(g.ex) o+=`\n${g.ex.replace("docker exec","docker exec -i")} bash -c 'cat > /tmp/runner.sh' <<'__BLK__'\n${body}exit 0
__BLK__\n${g.ex} bash /tmp/runner.sh </dev/null\n[ $? -ne 0 ] && exit 1\n`;
  else o+=`\n${body}`;
}
o+="\nexit 0\n";
fs.writeFileSync(out,o); console.log(`mode: ${MODE} blocks: ${n} run: ${run} skipped: ${skipped}`);
