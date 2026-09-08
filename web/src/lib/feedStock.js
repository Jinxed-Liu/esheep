import { decimalSum, negate } from './decimal.js';
export function feedStockBalance(batch, transactions) {
  const baseline = batch.remainingKilogramsText ?? batch.initialKilogramsText;
  const relevant=transactions.filter(t=>t.deletedAt==null&&t.ingredientBatchID===batch.id);
  if (baseline == null&&!relevant.some(t=>t.kindRawValue!=="conflict")) return null;
  return decimalSum([baseline??"0", ...relevant.map(t => t.kindRawValue === 'consumption' ? negate(t.quantityText) : t.kindRawValue === 'conflict' ? '0' : t.quantityText)]);
}
