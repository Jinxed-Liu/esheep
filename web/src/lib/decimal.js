// Decimal quantities stay decimal across stock arithmetic and CSV output.
function parts(value) {
  const match = /^(-?)(\d+)(?:\.(\d+))?$/.exec(String(value ?? "0"));
  if (!match) throw new Error(`数量不是有效十进制数：${value}`);
  return { integer: BigInt(`${match[1]}${match[2]}${match[3] ?? ""}`), scale: (match[3] ?? "").length };
}
function text(integer, scale) {
  const sign = integer < 0n ? "-" : "";
  const digits = (integer < 0n ? -integer : integer).toString().padStart(scale + 1, "0");
  return sign + (scale ? `${digits.slice(0, -scale)}.${digits.slice(-scale)}`.replace(/\.?0+$/, "") : digits);
}
export function decimalSum(values) {
  const rows = values.map(parts), scale = Math.max(0, ...rows.map((row) => row.scale));
  return text(rows.reduce((sum, row) => sum + row.integer * 10n ** BigInt(scale - row.scale), 0n), scale);
}
export function decimalMultiply(a, b) {
  const left = parts(a), right = parts(b); return text(left.integer * right.integer, left.scale + right.scale);
}
export function negate(value) { return String(value).startsWith("-") ? String(value).slice(1) : `-${value}`; }
export function decimalRound(value,scale=2,padded=false) {
 const p=parts(value),negative=p.integer<0n,n=negative?-p.integer:p.integer;
 let result=p.scale>scale?(n+10n**BigInt(p.scale-scale)/2n)/(10n**BigInt(p.scale-scale)):n*10n**BigInt(scale-p.scale);
 if(negative)result=-result;
 const normalized=text(result,scale);
 if(!padded)return normalized;
 const [whole,fraction=""]=normalized.split('.');return `${whole}.${fraction.padEnd(scale,'0')}`;
}
export function decimalDivide(a,b,scale=3) {
 const left=parts(a),right=parts(b);if(right.integer===0n)throw new Error('数量除数不能为零。');
 const n=left.integer*10n**BigInt(right.scale+scale),d=right.integer*10n**BigInt(left.scale);
 const negative=(n<0n)!==(d<0n),num=n<0n?-n:n,den=d<0n?-d:d;
 const rounded=(num+den/2n)/den;return text(negative?-rounded:rounded,scale);
}
