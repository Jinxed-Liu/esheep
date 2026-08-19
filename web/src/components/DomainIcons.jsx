import sheepIcon from "@iconify-icons/mdi/sheep";
import { Icon } from "@iconify/react";
import IconScaleOutline from "@tabler/icons-react/dist/esm/icons/IconScaleOutline.mjs";

export function SheepGlyph({ size = 24, className, "aria-hidden": ariaHidden = true }) {
  return <Icon icon={sheepIcon} width={size} height={size} className={className} aria-hidden={ariaHidden} />;
}

export function WeightGlyph({ size = 24, className, "aria-hidden": ariaHidden = true }) {
  return <IconScaleOutline size={size} className={className} aria-hidden={ariaHidden} stroke={1.8} />;
}
