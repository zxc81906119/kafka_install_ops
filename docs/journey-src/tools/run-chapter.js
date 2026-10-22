// usage: node gen.js <journey.md> <fromChapter> <toChapterExclusive> <out.sh>
// consecutive blocks on the same host/user run in ONE shell, fed from a file (stdin=/dev/null so ssh can't eat it)
const fs=require("fs"); const [,, md, from, to, out]=process.argv;
const s=fs.readFileSync(md,"utf8");
const a=s.indexOf(`\n# ${from}. `); let b=s.indexOf(`\n# ${to}. `); if(b<0) b=s.length;
if(a<0) throw new Error("chapter not found "+from);
const sec=s.slice(a,b);
const re=/\n(#{1,3} [^\n]+)|@role ([^\n]+)|```bash\n([\s\S]*?)```/g; let m, role=null, n=0, head="";
const groups=[];
while((m=re.exec(sec))){
  if(m[1]){ head=m[1]; continue; }
  if(m[2]){ const p=m[2].split("|").map(x=>x.trim()); role={who:p[0],host:p[1],user:p[2]}; continue; }
  const code=m[3]; n++;
  if(!role || role.host==="—" || /\s-it\s/.test(code)) { groups.push({key:"skip",blocks:[{n,head}]}); continue; }
  let ex=null, key="local";
  if(!/Windows/.test(role.host)) { const c= role.host==="dl01" ? "dl01" : `lab-${role.host}-1`; const u= role.user==="cpadmin" ? "-u cpadmin -w /home/cpadmin" : ""; ex=`docker exec ${u} ${c}`; key=c+"|"+role.user; }
  const g=groups[groups.length-1];
  if(g && g.key===key) g.blocks.push({n,head,code,host:role.host,user:role.user}); else groups.push({key,ex,blocks:[{n,head,code,host:role.host,user:role.user}]});
}
let o="set +e\nexport MSYS_NO_PATHCONV=1\ncd ~\n";
for(const g of groups){
  if(g.key==="skip"){ for(const bl of g.blocks) o+=`\necho "===== BLOCK ${bl.n} ${bl.head} skipped ====="\n`; continue; }
  let body="";
  for(const bl of g.blocks){
    body+=`echo "===== BLOCK ${bl.n} [${bl.host} ${bl.user}] ${bl.head} ====="\n${bl.code}rc=$?; echo "===== rc=$rc ====="; [ $rc -ne 0 ] && { echo "STOP at block ${bl.n}"; exit 1; }\n`;
  }
  if(g.ex) o+=`\n${g.ex.replace("docker exec","docker exec -i")} bash -c 'cat > /tmp/runner.sh' <<'__BLK__'\n${body}exit 0
__BLK__\n${g.ex} bash /tmp/runner.sh </dev/null\n[ $? -ne 0 ] && exit 1\n`;
  else o+=`\n${body}`;
}
fs.writeFileSync(out,o); console.log("blocks:",n,"groups:",groups.length);
