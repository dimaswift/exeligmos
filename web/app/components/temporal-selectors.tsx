import { useId } from "react";

import {
  SAROS_REALTIME_PERIODS,
  SAROS_REALTIME_RARITIES,
  type SarosRealtimeMinimumRarity,
  type SarosRealtimePeriodId,
} from "@exeligmos/temporal-core";

import styles from "./temporal-selectors.module.css";

export type TemporalPeriod = SarosRealtimePeriodId;
export type LowestRarity = SarosRealtimeMinimumRarity;

export const temporalPeriods: readonly TemporalPeriod[] = SAROS_REALTIME_PERIODS.map(
  (period) => period.id,
);
export const lowestRarities: readonly LowestRarity[] = SAROS_REALTIME_RARITIES.map(
  (rarity) => rarity.id,
);

export const temporalPeriodLabels = Object.freeze(
  Object.fromEntries(SAROS_REALTIME_PERIODS.map((period) => [period.id, period.title])),
) as Readonly<Record<TemporalPeriod, string>>;
export const lowestRarityLabels = Object.freeze(
  Object.fromEntries(SAROS_REALTIME_RARITIES.map((rarity) => [rarity.id, rarity.title])),
) as Readonly<Record<LowestRarity, string>>;

export interface TemporalPeriodSelectorProps {
  readonly value: TemporalPeriod;
  readonly onChange: (value: TemporalPeriod) => void;
  readonly label?: string;
  readonly className?: string;
}

/**
 * A bounded scale selector. Minus always moves toward Mili and plus always moves
 * toward Tera; the corresponding button disables at either end of the scale.
 */
export function TemporalPeriodSelector({
  value,
  onChange,
  label = "Temporal period",
  className,
}: TemporalPeriodSelectorProps) {
  const index = temporalPeriods.indexOf(value);
  const canDecrease = index > 0;
  const canIncrease = index < temporalPeriods.length - 1;

  return (
    <div
      aria-label={label}
      className={[styles.periodSelector, className].filter(Boolean).join(" ")}
      role="group"
    >
      <button
        aria-label={`Smaller period than ${temporalPeriodLabels[value]}`}
        className={styles.stepButton}
        disabled={!canDecrease}
        onClick={() => onChange(stepTemporalPeriod(value, -1))}
        title="Smaller period"
        type="button"
      >
        <span aria-hidden="true">−</span>
      </button>
      <output aria-atomic="true" aria-live="polite" className={styles.periodValue}>
        <small>{label}</small>
        <strong>{temporalPeriodLabels[value]}</strong>
      </output>
      <button
        aria-label={`Larger period than ${temporalPeriodLabels[value]}`}
        className={styles.stepButton}
        disabled={!canIncrease}
        onClick={() => onChange(stepTemporalPeriod(value, 1))}
        title="Larger period"
        type="button"
      >
        <span aria-hidden="true">+</span>
      </button>
    </div>
  );
}

export interface LowestRaritySelectorProps {
  readonly value: LowestRarity;
  readonly onChange: (value: LowestRarity) => void;
  readonly label?: string;
  readonly className?: string;
  /** Optional stable form name; an isolated generated name is used by default. */
  readonly name?: string;
}

export function LowestRaritySelector({
  value,
  onChange,
  label = "Lowest rarity",
  className,
  name,
}: LowestRaritySelectorProps) {
  const generatedName = useId();
  const groupName = name ?? `lowest-rarity-${generatedName}`;

  return (
    <fieldset className={[styles.raritySelector, className].filter(Boolean).join(" ")}>
      <legend>{label}</legend>
      <div className={styles.rarityOptions}>
        {lowestRarities.map((rarity) => (
          <label className={styles.rarityOption} data-rarity={rarity} key={rarity}>
            <input
              checked={rarity === value}
              name={groupName}
              onChange={() => onChange(rarity)}
              type="radio"
              value={rarity}
            />
            <span>{lowestRarityLabels[rarity]}</span>
          </label>
        ))}
      </div>
    </fieldset>
  );
}

export function stepTemporalPeriod(value: TemporalPeriod, direction: -1 | 1): TemporalPeriod {
  const index = temporalPeriods.indexOf(value);
  const nextIndex = Math.min(Math.max(index + direction, 0), temporalPeriods.length - 1);
  return temporalPeriods[nextIndex] ?? value;
}
