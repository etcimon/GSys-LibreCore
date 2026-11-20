/^[0-9a-f]+ </ {
  if (name != "") print name, n, jcc, call, ymm, mem, sz;
  name=$2; gsub(/[<>:]/,"",name); n=0; jcc=0; call=0; ymm=0; mem=0;
  sz=strtonum("0x" $1);
  next
}
/^ +[0-9a-f]+:/ {
  n++;
  line=$0; sub(/^ +[0-9a-f]+:\t? */,"",line);
  m=line; sub(/ .*/,"",m);
  if (m ~ /^j/) jcc++;
  else if (m=="call"||m=="callq") call++;
  if (m ~ /^v/) ymm++;
  if (line ~ /\(%r[sb]p\)|\(%rip\)/) mem++;
}
END { if (name != "") print name, n, jcc, call, ymm, mem, sz }
